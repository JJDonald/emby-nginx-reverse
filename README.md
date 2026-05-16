# Emby Nginx Reverse Proxy 一键部署脚本

交互式部署 Emby 的 Nginx 反代配置，支持两种结构：

1. **前后端一致**：所有请求直接反代到同一个 Emby 地址。
2. **前后端分离**：Web/API 走前端地址，播放/推流/长连接路径走后端推流域名。

脚本会先生成临时 HTTP 配置用于 Let’s Encrypt HTTP-01 验证，申请成功后自动切换到 HTTPS，并创建 HTTP -> HTTPS 跳转。

## 使用

```bash
sudo bash deploy-emby-nginx-reverse.sh
```

或者：

```bash
chmod +x deploy-emby-nginx-reverse.sh
sudo ./deploy-emby-nginx-reverse.sh
```

## 前提

- 需要一个公网域名，例如 `emby.example.com`
- 域名 A/AAAA 记录必须指向当前服务器
- 公网 80 端口必须可访问，用于 Let’s Encrypt HTTP-01 验证
- 如果服务器或云厂商有防火墙，需要放行 80/443

## 功能

- 自动检测并安装 nginx / certbot
- 自动申请 Let’s Encrypt 证书
- 自动创建 HTTP 跳转 HTTPS
- 交互选择前后端一致 / 前后端分离
- 自动生成 `/etc/nginx/conf.d/` 配置
- 覆盖旧配置前自动备份
- 执行 `nginx -t` 检查配置
- 自动 reload/restart nginx

## 注意

- Let’s Encrypt 不支持直接给 IP 签证书，必须使用域名。
- 证书默认保存在 `/etc/letsencrypt/live/<你的域名>/`。
- certbot 通常会自动安装续期定时任务，可用 `certbot renew --dry-run` 测试续期。
- 前后端分离模式内置了常见 Emby 推流、下载、WebSocket 路径；如有特殊路径，可手动编辑生成的 nginx 配置。
