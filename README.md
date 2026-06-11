# mimo-free-proxy

把小米 **MiMoCode** 的匿名免费通道（"MiMo Auto (free)"）封装成**标准 OpenAI 兼容接口**的极轻量单脚本方案。无需 CPA、无需 Node、无需数据库，仅依赖 `python3` + 服务管理器（systemd 或 OpenRC）。

一条命令即可在 Debian / Ubuntu / RHEL系 / Alpine 上得到一个可用的 OpenAI 兼容端点，末尾打印 **API 地址 / KEY / 模型名**。

---

## 一键安装

```bash
curl -L https://github.com/xuomen/mimo-free-proxy/raw/main/mimo_free_setup.sh | sudo bash
```

输出（只有这三行）：

```
API 地址: http://<你的IP>:8788/v1
API KEY : sk-mimo-xxxxxxxx
模型名  : mimo-auto
```

---

## 选项

| 选项 | 说明 |
|---|---|
| (无) | 对外监听 `0.0.0.0:8788`，自动生成 KEY |
| `--local` | 只监听 `127.0.0.1`（仅本机，最安全） |
| `--port N` | 自定义端口（默认 8788） |
| `--new-key` | 强制重新生成 API KEY（旧 KEY 立即失效，KEY 泄露时用） |
| `--uninstall` | 停服务 + 删 unit + 删 `/opt/mimo-free-proxy`，干净卸载 |
| `-h` / `--help` | 显示帮助 |

```bash
# 仅本机
curl -L https://github.com/xuomen/mimo-free-proxy/raw/main/mimo_free_setup.sh | sudo bash -s -- --local
# 自定义端口
... | sudo bash -s -- --port 9000
# 换 KEY
... | sudo bash -s -- --new-key
# 卸载
... | sudo bash -s -- --uninstall
```

> 本地已下载脚本时直接 `sudo bash mimo_free_setup.sh [选项]`。

---

## 客户端使用

### curl
```bash
curl http://<你的IP>:8788/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer *** \
  -d '{"model":"mimo-auto","messages":[{"role":"user","content":"你好"}],"max_tokens":1000}'
```

### OpenAI SDK (Python)
```python
from openai import OpenAI
client = OpenAI(base_url="http://<你的IP>:8788/v1", api_key="<你的KEY>")
print(client.chat.completions.create(
    model="mimo-auto",
    messages=[{"role": "user", "content": "你好"}],
    max_tokens=1000,
).choices[0].message.content)
```

---

## 兼容性

| 系统 | 服务管理 | 支持 |
|---|---|---|
| Debian 11/12/13 | systemd | ✅ |
| Ubuntu 20.04 ~ 26.04 | systemd | ✅ |
| RHEL / CentOS / Fedora | systemd | ✅ |
| **Alpine 3.x** | **OpenRC** | ✅ |
| 极简镜像（缺 curl 等） | — | ✅ 自动安装兜底 |

脚本自动检测 init 系统（systemd / OpenRC），自动用 `apt`/`dnf`/`yum`/`apk` 安装缺失依赖。

服务管理：

```bash
# systemd
systemctl status|restart mimo-free-proxy
journalctl -u mimo-free-proxy -f
# OpenRC (Alpine)
rc-service mimo-free-proxy status|restart
tail -f /var/log/mimo-free-proxy.log
```

- 代理脚本：`/opt/mimo-free-proxy/mimo_free_proxy.py`
- 配置（含 KEY）：`/opt/mimo-free-proxy/proxy.env`

---

## 重要说明与限制

- **KEY 幂等**：重跑安装（含 `curl|bash` 升级）会**保留原有 KEY**，只更新代理程序。要换 KEY 用 `--new-key`。
- **`mimo-auto` 是 reasoning 模型**：`max_tokens` 建议 ≥ 200，太小会被推理过程吃光导致 `content` 为空。
- **`max_tokens` 上限 131072**：超过自动钳制不报错；实际单次输出真实上限远低于此。
- **JWT 自动维护**：约 1 小时过期，代理提前 5 分钟刷新，遇 401/403 强制刷新重试，无需人工干预。
- **限流按「源出口 IP」计，不是按 key/指纹**：同一台 VPS 上申请多个 key/指纹**无法叠加并发**；扩容只能用**多出口 IP**（多 VPS / 代理池）。
- **纯 IPv6 VPS 注意**：若 VPS 只有 IPv6，输出地址会是 `http://[IPv6]:8788/v1`（已正确加方括号）。但**调用方也必须有公网 IPv6** 才能连上——很多家宽/手机网络没有 IPv6。这种情况建议**给域名套 Cloudflare**（Cloudflare 提供 IPv4 入口），否则没 IPv6 的客户端无法访问。
- **限时免费促销通道**：若 bootstrap 报错，可能是促销结束而非脚本故障。
- **公网暴露**：对外模式绑 `0.0.0.0`，脚本会提示防火墙放行命令（ufw/firewalld 检测），但**不自动改防火墙**；KEY 即访问凭据，勿泄露。本方案防护较弱，面向个人/小规模；大规模公开建议加 nginx 限流 + Cloudflare。

---

## License

MIT
