# Cloudflare → Nginx → sing-box VPS 安装器

这个仓库只包含 `install-cf-nginx-singbox.sh`，用于部署一个由 Cloudflare 橙云域名承载的网站与 VLESS 主节点。它与原有的直连 `install.sh` 属于两种不同架构；本仓库不会包含、更改或覆盖旧安装器。

## 架构

```text
客户端 → Cloudflare 橙云域名 :443 → Nginx :443 → VLESS + HTTPUpgrade
                                                ↓
                               sing-box 127.0.0.1:10000 → Internet

GitHub 网站内容仓库 → 每 5 分钟同步 → 同一域名的网站

备用客户端 → VPS_IP:8443 → VLESS + REALITY + Vision → Internet
```

## 部署

将你的网页提交到默认网站仓库 `https://github.com/xik54/nginx-site-content.git` 的 `site/` 或 `dist/` 目录。安装器会自动识别仓库的默认分支，因而不需要指定 `main` 或 `master`。

运行前：

1. 在 Cloudflare 中创建你的域名的 A 记录，指向 VPS 公网 IPv4，并开启橙云。
2. 在云厂商安全组放行 TCP `80`、`443`、`8443`。
3. 在 Ubuntu 或 Debian VPS 上下载并执行：

```bash
curl -fsSLO https://raw.githubusercontent.com/xik54/cf-nginx-singbox-installer/main/install-cf-nginx-singbox.sh
sudo bash install-cf-nginx-singbox.sh \
  --domain YOUR_DOMAIN \
  --ip YOUR_VPS_IPV4
```

若希望主节点和独立备用节点的最终代理出站使用官方 WARP SOCKS5，增加 `--with-warp-upstream`：

```bash
sudo bash install-cf-nginx-singbox.sh \
  --domain YOUR_DOMAIN \
  --ip YOUR_VPS_IPV4 \
  --with-warp-upstream
```

## 安装器会做什么

- 验证输入域名、VPS 实际公网 IPv4、DNS、现有的 80/443 端口及 Nginx 冲突；不覆盖未知服务。
- 安装 Nginx、Certbot、Git、sing-box、二维码工具，并尽力安装 Fail2Ban。
- 从 `xik54/nginx-site-content` 发布网页，之后每 5 分钟同步一次；网页同步不会覆盖代理 Nginx 配置。
- 为你输入的域名申请 Let's Encrypt 证书，并创建每天两次的续期 timer；只有实际续期后才重载 Nginx。
- Nginx 是公网 443 的唯一监听者；主 VLESS 仅绑定 `127.0.0.1:10000`，并使用随机 HTTPUpgrade 路径。
- 下载 Cloudflare IP 段，拒绝绕过 Cloudflare 直连源站的请求。
- 生成不经过 Nginx 的 `:8443` VLESS + REALITY + Vision 备用节点，且与主节点使用独立凭据。
- 生成主/备节点二维码；另生成两份含“国内直连、其他代理”规则的 sing-box 客户端 JSON。
- 启用可用的 `fq + bbr`，建立仅保护 SSH 的独立 Fail2Ban jail；启用 WARP 时还会建立 WARP 健康检查 timer。

## 输出位置

敏感凭据与客户端文件只保存在 VPS：

```text
/etc/sing-box-cf-nginx/credentials.env
/etc/sing-box-cf-nginx/client-profiles/
/etc/sing-box-cf-nginx/qr/
```

网站工作目录是 `/var/www/cf-nginx-singbox/current`；其来源始终是默认 GitHub 网站内容仓库，不需要在安装命令中另行填写。

## 限制与维护

- 同一台 VPS 上原有直连 sing-box 若占用 TCP 443，必须先自行决定迁移窗口；本脚本不会强行覆盖它。
- Cloudflare 主节点要求客户端支持 VLESS + TLS + HTTPUpgrade；备用二维码要求客户端支持 REALITY + Vision。
- 二维码只包含节点参数；需要分流规则时导入对应的 sing-box JSON。
- 后续检查：`sudo bash install-cf-nginx-singbox.sh --health-check`。
- 每次安装成功后会在 SSH 终端直接渲染主/备节点二维码，并列出 JSON 下载目录与 `scp` 命令；后续可随时运行 `sudo bash install-cf-nginx-singbox.sh --show-client-artifacts` 重新显示，且不会修改服务或凭据。
