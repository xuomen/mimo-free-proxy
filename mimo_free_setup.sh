#!/usr/bin/env bash
# ============================================================
# MiMo 免费通道 一键部署脚本 (单脚本方案, 不依赖 CPA)
# 运行后: 部署 stdlib Python 代理 + systemd 托管, 末尾打印 地址/KEY/模型
# 用法:  sudo bash mimo_free_setup.sh
#        sudo bash mimo_free_setup.sh --local     # 只监听 127.0.0.1 (本机用)
#        sudo bash mimo_free_setup.sh --port 9000  # 自定义端口
# ============================================================
set -euo pipefail

# ---------- 参数 ----------
BIND_HOST="0.0.0.0"      # 默认对外; --local 改为 127.0.0.1
PORT="8788"
APP_DIR="/opt/mimo-free-proxy"
PY_FILE="$APP_DIR/mimo_free_proxy.py"
ENV_FILE="$APP_DIR/proxy.env"
SVC="/etc/systemd/system/mimo-free-proxy.service"

while [ $# -gt 0 ]; do
  case "$1" in
    --local) BIND_HOST="127.0.0.1"; shift ;;
    --port)  PORT="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 依赖检查 + 自动安装兜底 ----------
APT_UPDATED=0
# 命令 -> 对应 apt 包名 (多数同名, 个别不同)
pkg_for() {
  case "$1" in
    python3)   echo "python3" ;;
    curl)      echo "curl" ;;
    grep)      echo "grep" ;;
    sed)       echo "sed" ;;
    od|head|tr|cut|install|env|chmod|mkdir|cat) echo "coreutils" ;;
    systemctl) echo "systemd" ;;
    *)         echo "$1" ;;
  esac
}

try_install() {
  local cmd="$1" pkg
  pkg="$(pkg_for "$cmd")"
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$APT_UPDATED" = "0" ]; then
      echo "   apt-get update ..."
      apt-get update -qq >/dev/null 2>&1 || true
      APT_UPDATED=1
    fi
    echo "   apt-get install $pkg ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q "$pkg" >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q "$pkg" >/dev/null 2>&1 || true
  fi
}

# 核心依赖: 缺失且装不上则退出
CORE_DEPS="python3 systemctl"
# 可选依赖: 缺失尝试装, 装不上仅警告(不影响主体)
OPT_DEPS="curl grep sed coreutils-od"

echo "==> 检查核心依赖 ($CORE_DEPS)"
for c in $CORE_DEPS; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "   缺少 $c, 尝试自动安装..."
    try_install "$c"
    command -v "$c" >/dev/null 2>&1 || { echo "错误: $c 不可用且无法自动安装, 终止。"; exit 1; }
  fi
done

echo "==> 检查可选依赖 (curl/grep/sed/od)"
for c in curl grep sed od; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "   缺少 $c, 尝试自动安装..."
    try_install "$c"
    command -v "$c" >/dev/null 2>&1 || echo "   ($c 仍不可用, 主体部署不受影响, 相关验证步骤将跳过)"
  fi
done

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

# ---------- 生成访问 KEY (幂等: 已存在则复用) ----------
if [ -f "$ENV_FILE" ] && grep -q '^MIMO_PROXY_KEY=' "$ENV_FILE"; then
  API_KEY="$(grep '^MIMO_PROXY_KEY=' "$ENV_FILE" | cut -d= -f2-)"
  echo "==> 复用已有 KEY"
else
  API_KEY="sk-mimo-$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "==> 生成新 KEY"
fi

cat > "$ENV_FILE" <<ENVEOF
MIMO_PROXY_HOST=$BIND_HOST
MIMO_PROXY_PORT=$PORT
MIMO_PROXY_KEY=$API_KEY
MIMO_FREE_CLIENT_FILE=$APP_DIR/mimo-free-client
ENVEOF
chmod 600 "$ENV_FILE"

# ---------- systemd 服务 ----------
echo "==> 写入 systemd 服务"
cat > "$SVC" <<SVCEOF
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
systemctl enable --now mimo-free-proxy.service >/dev/null 2>&1 || systemctl restart mimo-free-proxy.service
sleep 4

# ---------- 验证 ----------
echo "==> 验证服务"
ACTIVE="$(systemctl is-active mimo-free-proxy.service || true)"
HEALTH="$(curl -s -m 8 "http://127.0.0.1:$PORT/v1/health" || true)"

# 真实 chat 冒烟 (用 KEY)
SMOKE="$(curl -s -m 60 "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model":"mimo-auto","messages":[{"role":"user","content":"说三个字:已就绪"}],"max_tokens":250}' || true)"

# 取公网 IP (对外模式)
if [ "$BIND_HOST" = "0.0.0.0" ]; then
  PUBIP="$(curl -s -m 8 ifconfig.me 2>/dev/null || curl -s -m 8 ip.sb 2>/dev/null || echo '<本机公网IP>')"
  ADDR="http://$PUBIP:$PORT/v1"
else
  ADDR="http://127.0.0.1:$PORT/v1"
fi

echo ""
echo "=================================================================="
echo "  MiMo 免费通道 部署完成"
echo "=================================================================="
echo "  服务状态 : $ACTIVE"
echo "  健康检查 : $HEALTH"
if echo "$SMOKE" | grep -q '"content"'; then
  echo "  冒烟测试 : 通过 (上游返回正常)"
else
  echo "  冒烟测试 : 未通过 - 响应片段: $(echo "$SMOKE" | head -c 200)"
  echo "             (若为限流/促销结束, 服务本身正常, 稍后重试)"
fi
echo "------------------------------------------------------------------"
echo "  API 地址 (Base URL): $ADDR"
echo "  API KEY            : $API_KEY"
echo "  模型名 (Model)     : mimo-auto"
echo "------------------------------------------------------------------"
echo "  调用示例:"
echo "  curl $ADDR/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Authorization: Bearer $API_KEY' \\"
echo "    -d '{\"model\":\"mimo-auto\",\"messages\":[{\"role\":\"user\",\"content\":\"你好\"}],\"max_tokens\":1000}'"
echo "=================================================================="
if [ "$BIND_HOST" = "0.0.0.0" ]; then
  echo "  提示: 已对外监听 $PORT, 请确认防火墙/安全组放行该端口。"
  echo "        KEY 即访问凭据, 勿泄露。"
fi
