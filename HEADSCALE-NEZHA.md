# Fork 说明：Headscale + 哪吒版 render-engine

本 fork 基于上游 dengyie/render-engine，改动只有两处，其余（ttyd
Web 终端 + tmux、OpenSSH、Caddy、sing-box、保活）与上游一致：

| 上游 | 本 fork |
| --- | --- |
| EasyTier 虚拟网格 | Tailscale 客户端，接自部署 Headscale |
| Komari / MangoHub 探针 | 官方哪吒 agent v2 线（nezhahq/agent v2.3.5），对应 2.x 面板 |

## 1. 为什么 Tailscale 要用用户态模式

Render 免费容器没有 `/dev/net/tun`、没有 `CAP_NET_ADMIN`，所以
`tailscaled` 以 `--tun=userspace-networking` 运行（gVisor netstack）。
这意味着：

- 节点仍能拿到 tailnet IP、在 Headscale 里可见；
- `tailscale serve tcp:22 -> 127.0.0.1:22` 把 tailnet 的 22 端口转发到
  本地 sshd，从 tailnet 内任意节点 `ssh root@<tailnet-ip>` 即可登录
  （密码即 `SSH_PASS`，或 `SSH_PUBKEY` 的密钥）；
- 但它**不是**一个真正的系统网卡：容器内其他程序不会自动走
  tailnet，只有走 `127.0.0.1:1055` SOCKS5 代理的程序才能经 tailnet
  出站。Web 终端 `/shell/` 不受影响，始终可用。

## 2. Headscale 侧准备

在你的 Headscale 服务器上生成一个**可复用**的预授权 key（容器每次
重启/重新部署都会重新登录，不可复用的 key 第二次就失效）：

```bash
headscale users create render   # 若还没有用户
headscale preauthkeys create --user render --reusable --expiration 90d
```

Render 环境变量：

| 变量 | 说明 |
| --- | --- |
| `ENABLE_TAILSCALE` | `true` |
| `HEADSCALE_URL` | 自部署 Headscale 地址，如 `https://headscale.example.com` |
| `TS_AUTHKEY` | 上一步生成的 key |
| `TS_HOSTNAME` | 默认 `render-box` |
| `TS_EPHEMERAL` | `false`（默认）；`true` 则容器停掉后节点自动从 Headscale 消失 |

部署后在日志里找 `Tailscale up OK. Tailnet IP:`，并在 Headscale
里确认节点在线；若 `tailscale up failed`，先查 key 是否可复用、
URL 是否能从公网访问。

## 3. 哪吒侧准备

在你的哪吒面板里添加一台服务器，拿到安装命令里的两个值：

| 变量 | 说明 |
| --- | --- |
| `NZ_SERVER` | 面板 gRPC 地址，带端口，如 `nz.example.com:5555`（注意：不是面板 Web 地址 `https://nz.example.com`，也不是 443 端口） |
| `NZ_CLIENT_SECRET` | 面板给出的 client secret |
| `NZ_UUID` | 已由 `render.yaml` 的 `generateValue` 生成并固定在服务上；**不要**每次手动改，否则面板里会多出一台 |
| `NZ_TLS` | 仅当 gRPC 走 TLS 时设 `true`，默认 `false` |
| `NZ_INSECURE_TLS` | `NZ_TLS=true` 时默认 `true`（自签/反代证书常见） |

哪吒 agent 由官方 NZ_* 环境变量驱动（`NZ_SERVER` /
`NZ_CLIENT_SECRET` / `NZ_UUID` / `NZ_TLS` / `NZ_INSECURE_TLS`），
并固定 `NZ_DISABLE_AUTO_UPDATE=true`（Render 容器内自动更新无意义）、
`NZ_SKIP_CONNECTION_COUNT=true`、`NZ_SKIP_PROCS_COUNT=true`、
`NZ_REPORT_DELAY=3`。

注意：Render 磁盘是临时的，面板里看到的磁盘容量可能仍是宿主
OverlayFS 的数值（上游 Komari 版用 `KOMARI_FORCE_DISK_TOTAL`
归一化，官方哪吒 agent 没有等价开关），以实际 `du` 为准，不要
按面板磁盘百分比删文件。

## 4. Render 部署

优先用 Blueprint（`render.yaml` 已含全部变量，`plan: free`，
`region: singapore`，健康检查 `/health`）：

```
https://render.com/deploy?repo=https://github.com/wang4386/render-engine
```

填好上表变量后 Apply，盯 Build 日志到 `Live`，再看 Deploy 日志
确认三行：`Tailscale up OK`、`Nezha agent is ENABLED`、
`render-engine is ready!`。随后分别在 Headscale 节点列表和哪吒
面板里确认这台机器上线。

版本说明：面板版本以用户 2026-10-20 确认的 2.3.18 为准，故 agent
用 v2 线；面板公开页页脚的「ZOOL 主题 v1.0.0」是主题版本，不是
哪吒版本，不要拿它判断 agent 版本。若面板实际是 v1，才需要把
Dockerfile 里的 `NEZHA_VERSION` 换回 v1.15.0。
