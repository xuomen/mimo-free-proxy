# mimo-free-proxy

把小米 **MiMoCode** 的匿名免费通道（"MiMo Auto (free)"）封装成**标准 OpenAI 兼容接口**的极轻量单脚本方案。无需 CPA、无需 Node、无需数据库，仅依赖 `python3` + `systemd`。

运行一条命令即可在任意 Debian/Ubuntu VPS 上得到一个可用的 OpenAI 兼容端点，末尾自动打印 **API 地址 / KEY / 模型名**。

---

## 这是什么

MiMoCode（小米，OpenCode 分支）内置一个 **零配置、免登录** 的免费推理通道。它不是固定 API key，而是**设备指纹 → JWT** 的匿名流程：

```
指纹 fingerprint
  → POST /api/free-ai/bootstrap
  → 拿到 1 小时 JWT
  → POST /api/free-ai/openai/chat   (model 固定 mimo-auto)
```

本项目用一个纯标准库的 Python 代理把上述流程封装好，对外暴露成人人会用的：

```
POST /v1/chat/completions
GET  /v1/models
GET  /v1/health
```

代理会自动生成指纹、自动 bootstrap、JWT 过期自动刷新、把路径改写到上游真实路径、强制模型名为 `mimo-auto`、并钳制 `max_tokens` 上限，让任何标准 OpenAI 客户端开箱即用。

---

## 快速开始

```bash
# 对外暴露（默认端口 8788，自动生成访问 KEY）
sudo bash mimo_free_setup.sh

# 只本机使用（监听 127.0.0.1，最安全）
sudo bash mimo_free_setup.sh --local

# 自定义端口
sudo bash mimo_free_setup.sh --port 9000
```

运行结束后，shell 会打印：

```
==================================================================
  MiMo 免费通道 部署完成
==================================================================
  服务状态 : active
  健康检查 : {"status": "ok"}
  冒烟测试 : 通过 (上游返回正常)
------------------------------------------------------------------
  API 地址 (Base URL): http://<你的IP>:8788/v1
  API KEY            : sk-mimo-xxxxxxxxxxxxxxxx
  模型名 (Model)     : mimo-auto
==================================================================
```

---

## 客户端使用

### curl
```bash
curl http://<你的IP>:8788/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <你的KEY>' \
  -d '{"model":"mimo-auto","messages":[{"role":"user","content":"你好"}],"max_tokens":1000}'
```

### OpenAI SDK (Python)
```python
from openai import OpenAI
client = OpenAI(base_url="http://<你的IP>:8788/v1", api_key="<你的KEY>")
resp = client.chat.completions.create(
    model="mimo-auto",
    messages=[{"role": "user", "content": "你好"}],
    max_tokens=1000,
)
print(resp.choices[0].message.content)
```

---

## 部署后管理

```bash
systemctl status  mimo-free-proxy
systemctl restart mimo-free-proxy
journalctl -u mimo-free-proxy -f
```

- 代理脚本：`/opt/mimo-free-proxy/mimo_free_proxy.py`
- 配置（含 KEY）：`/opt/mimo-free-proxy/proxy.env`
- 设备指纹：`/opt/mimo-free-proxy/mimo-free-client`

---

## 兼容性

| 系统 | 支持 |
|---|---|
| Debian 11/12/13 | ✅ |
| Ubuntu 20.04 ~ 26.04 | ✅ |
| 极简镜像（缺 curl 等） | ✅ 脚本自动安装兜底 |
| Alpine (无 systemd) | ❌ 需改 OpenRC |

脚本对所有依赖（`python3`/`systemd` 核心，`curl`/`grep`/`sed`/`od` 可选）都做了 apt/dnf/yum 自动安装兜底。

---

## 重要说明与限制

- **`mimo-auto` 是 reasoning 模型**：`max_tokens` 建议 ≥ 200，太小会被推理过程吃光导致 `content` 为空。
- **`max_tokens` 上限 131072**：超过会被代理自动钳制，不会报错。实际单次输出真实上限远低于此（模型自行 `finish_reason=stop`）。
- **JWT 自动维护**：约 1 小时过期，代理提前 5 分钟刷新，遇 401/403 强制刷新重试，无需人工干预。
- **限流按「源出口 IP」计，不是按 key/指纹**：实测同一台机器上换新指纹照样限流。所以**同一 VPS 上申请多个 key/指纹无法叠加并发**；要扩容只能用**多出口 IP**（多 VPS / 代理池）。
- **这是限时免费促销通道**：若 bootstrap 开始报错，可能是促销结束，而非脚本故障。
- **公网暴露**：脚本绑 `0.0.0.0` 时请自行放行防火墙/安全组端口；KEY 即访问凭据，勿泄露。本方案防护较弱，面向个人/小规模；大规模公开建议加 nginx 限流 + Cloudflare。

---

## License

MIT
