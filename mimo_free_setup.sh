#!/usr/bin/env bash
# ============================================================
# MiMo 免费通道 一键部署脚本 (单脚本方案, 不依赖 CPA)
# 兼容: Debian/Ubuntu(systemd) / RHEL系(systemd) / Alpine(OpenRC)
# 运行后: 部署 stdlib Python 代理 + 服务托管, 末尾打印 地址/KEY/模型
# ============================================================
set -euo pipefail

# ---------- 默认参数 ----------
BIND_HOST="0.0.0.0"      # 默认对外; --local 改为 127.0.0.1
PORT="8788"
ACTION="install"         # install | uninstall
NEW_KEY=0                # --new-key 强制重新生成 KEY
APP_DIR="/opt/mimo-free-proxy"
PY_FILE="$APP_DIR/mimo_free_proxy.py"
ENV_FILE="$APP_DIR/proxy.env"
SVC_NAME="mimo-free-proxy"
SVC_SYSTEMD="/etc/systemd/system/${SVC_NAME}.service"
SVC_OPENRC="/etc/init.d/${SVC_NAME}"

usage() {
  cat <<'USAGE'
MiMo 免费通道 一键部署脚本

用法:
  bash mimo_free_setup.sh [选项]

选项:
  --local         只监听 127.0.0.1 (仅本机使用, 不对外)
  --port N        自定义端口 (默认 8788)
  --new-key       强制重新生成 API KEY (旧 KEY 立即失效)
  --uninstall     停止并彻底卸载 (删服务/目录/KEY)
  -h, --help      显示本帮助

示例:
  bash mimo_free_setup.sh                 # 对外, 默认端口
  bash mimo_free_setup.sh --local         # 仅本机
  bash mimo_free_setup.sh --port 9000     # 自定义端口
  bash mimo_free_setup.sh --new-key       # 换 KEY
  bash mimo_free_setup.sh --uninstall     # 卸载

兼容 Debian/Ubuntu/RHEL(systemd) 与 Alpine(OpenRC), 缺失依赖自动安装。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local)     BIND_HOST="127.0.0.1"; shift ;;
    --port)      PORT="${2:?--port 需要一个端口号}"; shift 2 ;;
    --new-key)   NEW_KEY=1; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "未知参数: $1"; echo; usage; exit 1 ;;
  esac
done

# ---------- 检测 init 系统 ----------
# INIT=systemd | openrc
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  INIT="systemd"
elif command -v rc-update >/dev/null 2>&1 || [ -f /sbin/openrc ] || grep -qi alpine /etc/os-release 2>/dev/null; then
  INIT="openrc"
elif command -v systemctl >/dev/null 2>&1; then
  INIT="systemd"
else
  INIT="none"
fi

# ---------- 卸载 ----------
if [ "$ACTION" = "uninstall" ]; then
  echo "==> 卸载 $SVC_NAME ..."
  if [ "$INIT" = "systemd" ]; then
    systemctl disable --now "${SVC_NAME}.service" >/dev/null 2>&1 || true
    rm -f "$SVC_SYSTEMD"
    systemctl daemon-reload >/dev/null 2>&1 || true
  elif [ "$INIT" = "openrc" ]; then
    rc-service "$SVC_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SVC_NAME" >/dev/null 2>&1 || true
    rm -f "$SVC_OPENRC"
  fi
  # 兜底杀残留进程
  pkill -f "$PY_FILE" >/dev/null 2>&1 || true
  rm -rf "$APP_DIR"
  echo "已卸载: 服务/目录/KEY 全部删除。"
  exit 0
fi

# ---------- 依赖检查 + 自动安装兜底 ----------
PKG_UPDATED=0
pkg_for() {
  # 命令 -> 包名 (按发行版差异返回)
  case "$1" in
    python3)   [ "$INIT" = "openrc" ] && echo "python3" || echo "python3" ;;
    curl)      echo "curl" ;;
    grep)      echo "grep" ;;
    sed)       echo "sed" ;;
    od|head|tr|cut|install|env|chmod|mkdir|cat)
               [ "$INIT" = "openrc" ] && echo "coreutils" || echo "coreutils" ;;
    *)         echo "$1" ;;
  esac
}

try_install() {
  local cmd="$1" pkg
  pkg="$(pkg_for "$cmd")"
  if command -v apk >/dev/null 2>&1; then
    if [ "$PKG_UPDATED" = "0" ]; then echo "   apk update ..."; apk update >/dev/null 2>&1 || true; PKG_UPDATED=1; fi
    echo "   apk add $pkg ..."
    apk add --no-cache "$pkg" >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    if [ "$PKG_UPDATED" = "0" ]; then echo "   apt-get update ..."; apt-get update -qq >/dev/null 2>&1 || true; PKG_UPDATED=1; fi
    echo "   apt-get install $pkg ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$pkg" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$pkg" >/dev/null 2>&1 || true
  fi
}

echo "==> init 系统: $INIT"
if [ "$INIT" = "none" ]; then
  echo "错误: 未检测到 systemd 或 OpenRC, 无法托管服务, 终止。"; exit 1
fi

echo "==> 检查核心依赖 (python3)"
if ! command -v python3 >/dev/null 2>&1; then
  echo "   缺少 python3, 尝试自动安装..."
  try_install python3
  command -v python3 >/dev/null 2>&1 || { echo "错误: python3 不可用且无法自动安装, 终止。"; exit 1; }
fi

echo "==> 检查可选依赖 (curl/grep/sed/od)"
for c in curl grep sed od; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "   缺少 $c, 尝试自动安装..."
    try_install "$c"
    command -v "$c" >/dev/null 2>&1 || echo "   ($c 仍不可用, 主体部署不受影响, 相关验证步骤将跳过)"
  fi
done

# ---------- 端口占用检测 ----------
echo "==> 检查端口 $PORT 占用"
PORT_BUSY=""
if command -v ss >/dev/null 2>&1; then
  PORT_BUSY="$(ss -ltn 2>/dev/null | grep -E "[:.]${PORT}\b" || true)"
elif command -v netstat >/dev/null 2>&1; then
  PORT_BUSY="$(netstat -ltn 2>/dev/null | grep -E "[:.]${PORT}\b" || true)"
fi
if [ -n "$PORT_BUSY" ]; then
  # 若占用者就是本服务, 视为升级重装, 放行; 否则报错
  if pgrep -f "$PY_FILE" >/dev/null 2>&1; then
    echo "   端口 $PORT 由本服务占用 -> 视为升级重装, 继续。"
  else
    echo "错误: 端口 $PORT 已被其他进程占用, 请换 --port 或先释放该端口:"
    echo "$PORT_BUSY"
    exit 1
  fi
fi

# 记录是否为升级(目录已存在)
UPGRADE=0
[ -f "$PY_FILE" ] && UPGRADE=1

echo "==> 创建目录 $APP_DIR"
mkdir -p "$APP_DIR"

# ---------- 写入代理脚本 (stdlib only) ----------
echo "==> 写入代理脚本"
cat > "$PY_FILE" <<'PYEOF'
#!/usr/bin/env python3
"""MiMo 免费通道 -> 标准 OpenAI 端点 (stdlib only, 单文件)。
指纹->bootstrap->JWT(1h自动刷新)->/api/free-ai/openai/chat, 模型强制 mimo-auto。"""
import json, os, sys, time, base64, hashlib, threading, platform
import urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("MIMO_FREE_BASE_URL", "https://api.xiaomimimo.com").rstrip("/")
BOOTSTRAP_URL = f"{UPSTREAM}/api/free-ai/bootstrap"
CHAT_URL = f"{UPSTREAM}/api/free-ai/openai/chat"
CLIENT_FILE = os.environ.get("MIMO_FREE_CLIENT_FILE", "/opt/mimo-free-proxy/mimo-free-client")
LISTEN_HOST = os.environ.get("MIMO_PROXY_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("MIMO_PROXY_PORT", "8788"))
LOCAL_KEY = os.environ.get("MIMO_PROXY_KEY", "")
UPSTREAM_MODEL = "mimo-auto"
MAX_OUTPUT_TOKENS = 131072
REFRESH_MARGIN = 300

# 上游 body 校验: 请求必须带官方 MiMoCode system prompt 首句, 否则 403 Illegal access。
# proxy 自动注入此 guard 作为 messages 第一条 system message。
MIMO_GUARD_TEXT = (
    "You are MiMoCode, an interactive CLI tool that helps users with "
    "software engineering tasks. Use the instructions below and the tools "
    "available to you to assist the user.\n\n"
    "IMPORTANT: You must NEVER generate or guess URLs for the user unless you "
    "are confident that the URLs are for helping the user with programming. "
    "You may use URLs provided by the user in their messages or local files.\n\n"
    "IMPORTANT: Assist with authorized security testing, defensive security, "
    "CTF challenges, and educational contexts."
)

_jwt = None
_jwt_exp = 0
_lock = threading.Lock()

def log(*a):
    print(f"[{time.strftime('%H:%M:%S')}]", *a, file=sys.stderr, flush=True)

def get_fp():
    try:
        v = open(CLIENT_FILE).read().strip()
        if v:
            return v
    except Exception:
        pass
    cpu = platform.processor() or "x86_64"
    try:
        user = os.getlogin()
    except Exception:
        user = os.environ.get("USER", "root")
    raw = "|".join([platform.node(), "linux", "x64", cpu, user])
    fp = hashlib.sha256(raw.encode()).hexdigest()
    try:
        os.makedirs(os.path.dirname(CLIENT_FILE), exist_ok=True)
        open(CLIENT_FILE, "w").write(fp)
        os.chmod(CLIENT_FILE, 0o600)
    except Exception as e:
        log("warn: cannot persist fingerprint", e)
    return fp

def _decode_exp(jwt):
    try:
        p = json.loads(base64.urlsafe_b64decode(jwt.split(".")[1] + "=="))
        if isinstance(p.get("exp"), (int, float)):
            return p["exp"] * 1000
    except Exception:
        pass
    return time.time() * 1000 + 3600 * 1000

def _bootstrap():
    body = json.dumps({"client": get_fp()}).encode()
    req = urllib.request.Request(BOOTSTRAP_URL, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read().decode())
    jwt = data.get("jwt")
    if not jwt:
        raise RuntimeError("bootstrap missing jwt")
    return jwt, _decode_exp(jwt)

def get_jwt(force=False):
    global _jwt, _jwt_exp
    with _lock:
        now = time.time() * 1000
        if not force and _jwt and (_jwt_exp - now) > REFRESH_MARGIN * 1000:
            return _jwt
        _jwt, _jwt_exp = _bootstrap()
        log(f"JWT refreshed, exp in {int((_jwt_exp-now)/1000)}s")
        return _jwt

def upstream_chat(payload):
    payload = dict(payload)
    payload["model"] = UPSTREAM_MODEL
    # 注入官方 guard system prompt (上游 body 校验要求, 否则 403 Illegal access)
    if MIMO_GUARD_TEXT:
        msgs = list(payload.get("messages") or [])
        already = (msgs and msgs[0].get("role") == "system"
                   and isinstance(msgs[0].get("content"), str)
                   and msgs[0]["content"].startswith(MIMO_GUARD_TEXT[:80]))
        if not already:
            msgs.insert(0, {"role": "system", "content": MIMO_GUARD_TEXT})
            payload["messages"] = msgs
    for f in ("max_tokens", "max_completion_tokens"):
        v = payload.get(f)
        if isinstance(v, int) and v > MAX_OUTPUT_TOKENS:
            log(f"clamp {f} {v} -> {MAX_OUTPUT_TOKENS}")
            payload[f] = MAX_OUTPUT_TOKENS
    def _do(jwt):
        body = json.dumps(payload).encode()
        req = urllib.request.Request(CHAT_URL, data=body, method="POST",
            headers={"Authorization": f"Bearer {jwt}",
                     "X-Mimo-Source": "mimocode-cli-free",
                     "Content-Type": "application/json"})
        return urllib.request.urlopen(req, timeout=300)
    try:
        return _do(get_jwt())
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            log("got", e.code, "-> refresh JWT retry")
            return _do(get_jwt(force=True))
        raise

MODELS_RESP = {"object": "list", "data": [
    {"id": "mimo-auto", "object": "model", "created": 0, "owned_by": "xiaomi-mimo-free"}]}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _auth_ok(self):
        if not LOCAL_KEY:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {LOCAL_KEY}"
    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a):
        pass
    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            if not self._auth_ok():
                return self._json(401, {"error": {"message": "invalid key"}})
            return self._json(200, MODELS_RESP)
        if self.path.rstrip("/").endswith("/health"):
            return self._json(200, {"status": "ok"})
        self._json(404, {"error": {"message": "not found"}})
    def do_POST(self):
        if "/chat/completions" not in self.path:
            return self._json(404, {"error": {"message": "not found"}})
        if not self._auth_ok():
            return self._json(401, {"error": {"message": "invalid key"}})
        try:
            n = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(n).decode())
        except Exception as e:
            return self._json(400, {"error": {"message": f"bad request: {e}"}})
        try:
            resp = upstream_chat(payload)
        except urllib.error.HTTPError as e:
            body = e.read().decode(errors="replace")
            try:
                obj = json.loads(body)
            except Exception:
                obj = {"error": {"message": body[:500], "code": e.code}}
            return self._json(e.code, obj)
        except Exception as e:
            return self._json(502, {"error": {"message": str(e)}})
        self.send_response(200)
        self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except Exception as e:
            log("stream relay ended", repr(e))
        finally:
            resp.close()

def main():
    get_fp()
    try:
        get_jwt()
        log("startup JWT ok")
    except Exception as e:
        log("startup bootstrap failed (will retry on request):", e)
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    log(f"MiMo Free Proxy on http://{LISTEN_HOST}:{LISTEN_PORT}  auth={'ON' if LOCAL_KEY else 'OFF'}")
    srv.serve_forever()

if __name__ == "__main__":
    main()
PYEOF
chmod 644 "$PY_FILE"

# ---------- 生成访问 KEY (幂等: 已存在则复用; --new-key 强制重新生成) ----------
if [ "$NEW_KEY" = "0" ] && [ -f "$ENV_FILE" ] && grep -q '^MIMO_PROXY_KEY=' "$ENV_FILE"; then
  API_KEY="$(grep '^MIMO_PROXY_KEY=' "$ENV_FILE" | cut -d= -f2-)"
  echo "==> 复用已有 KEY"
else
  API_KEY="sk-mimo-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ "$NEW_KEY" = "1" ] && echo "==> 强制生成新 KEY (旧 KEY 已失效)" || echo "==> 生成新 KEY"
fi

cat > "$ENV_FILE" <<ENVEOF
MIMO_PROXY_HOST=$BIND_HOST
MIMO_PROXY_PORT=$PORT
MIMO_PROXY_KEY=$API_KEY
MIMO_FREE_CLIENT_FILE=$APP_DIR/mimo-free-client
ENVEOF
chmod 600 "$ENV_FILE"

# ---------- 安装/重启服务 (systemd 或 OpenRC) ----------
if [ "$INIT" = "systemd" ]; then
  echo "==> 写入 systemd 服务"
  cat > "$SVC_SYSTEMD" <<SVCEOF
[Unit]
Description=MiMo Free OpenAI-compatible Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/env python3 $PY_FILE
Restart=always
RestartSec=3
StartLimitIntervalSec=60
StartLimitBurst=10

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl daemon-reload
  systemctl enable --now "${SVC_NAME}.service" >/dev/null 2>&1 || systemctl restart "${SVC_NAME}.service"
elif [ "$INIT" = "openrc" ]; then
  echo "==> 写入 OpenRC 服务"
  cat > "$SVC_OPENRC" <<'RCEOF'
#!/sbin/openrc-run
description="MiMo Free OpenAI-compatible Proxy"
command="/usr/bin/env"
command_args="python3 /opt/mimo-free-proxy/mimo_free_proxy.py"
command_background=true
pidfile="/run/mimo-free-proxy.pid"
output_log="/var/log/mimo-free-proxy.log"
error_log="/var/log/mimo-free-proxy.log"

depend() {
    need net
    after firewall
}

start_pre() {
    set -a
    [ -f /opt/mimo-free-proxy/proxy.env ] && . /opt/mimo-free-proxy/proxy.env
    set +a
}
RCEOF
  chmod +x "$SVC_OPENRC"
  rc-update add "$SVC_NAME" default >/dev/null 2>&1 || true
  rc-service "$SVC_NAME" restart >/dev/null 2>&1 || rc-service "$SVC_NAME" start >/dev/null 2>&1 || true
fi
sleep 4

# ---------- 验证(静默, 仅确认服务起来) ----------
curl -s -m 8 "http://127.0.0.1:$PORT/v1/health" >/dev/null 2>&1 || true

# 取公网 IP (对外模式): 优先 IPv4, 无 IPv4 才用 IPv6(加方括号)
if [ "$BIND_HOST" = "0.0.0.0" ]; then
  IP4="$(curl -s -4 -m 8 ifconfig.me 2>/dev/null || curl -s -4 -m 8 ip.sb 2>/dev/null || true)"
  if [ -n "$IP4" ]; then
    HOSTPART="$IP4"
  else
    IP6="$(curl -s -6 -m 8 ifconfig.me 2>/dev/null || curl -s -6 -m 8 ip.sb 2>/dev/null || true)"
    if [ -n "$IP6" ]; then
      HOSTPART="[$IP6]"          # IPv6 必须用方括号包裹
    else
      HOSTPART="<本机公网IP>"
    fi
  fi
  ADDR="http://$HOSTPART:$PORT/v1"
else
  ADDR="http://127.0.0.1:$PORT/v1"
fi

# ---------- 防火墙放行提示 (对外模式, 仅提示不自动改) ----------
if [ "$BIND_HOST" = "0.0.0.0" ] && [ "$UPGRADE" = "0" ]; then
  FW_HINT=""
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    FW_HINT="ufw allow ${PORT}/tcp"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    FW_HINT="firewall-cmd --add-port=${PORT}/tcp --permanent && firewall-cmd --reload"
  fi
  [ -n "$FW_HINT" ] && echo "提示: 检测到防火墙启用, 如外部连不上请放行端口: $FW_HINT" >&2
fi

echo ""
echo "API 地址: $ADDR"
echo "API KEY : $API_KEY"
echo "模型名  : mimo-auto"
