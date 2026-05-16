# Emby Nginx Reverse Proxy 一键部署脚本

交互式部署 Emby 的 Nginx 反代配置，支持两种结构：

1. **前后端一致**：所有请求直接反代到同一个 Emby 地址。
2. **前后端分离**：Web/API 走前端地址，播放/推流/长连接路径走后端推流域名。

## 使用

```bash
sudo bash deploy-emby-nginx-reverse.sh
```

或者：

```bash
chmod +x deploy-emby-nginx-reverse.sh
sudo ./deploy-emby-nginx-reverse.sh
```

## 功能

- 自动检测并安装 nginx
- 交互选择前后端一致 / 前后端分离
- 自动生成 `/etc/nginx/conf.d/` 配置
- 覆盖旧配置前自动备份
- 执行 `nginx -t` 检查配置
- 自动 reload/restart nginx

## 注意

- 脚本默认只生成 HTTP 配置。
- HTTPS 可后续使用 certbot/acme 单独配置。
- 前后端分离模式内置了常见 Emby 推流、下载、WebSocket 路径；如有特殊路径，可手动编辑生成的 nginx 配置。
