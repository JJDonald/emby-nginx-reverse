# Emby Nginx Reverse Proxy 一键部署脚本

交互式部署 Emby 的 Nginx 反代配置，支持两种结构：

1. **前后端一致**：所有请求直接反代到同一个 Emby 地址。
2. **前后端分离**：Web/API 走前端地址，播放/推流/长连接路径走后端推流域名。

脚本会自动生成 **自签 HTTPS 证书**，并创建 HTTP -> HTTPS 跳转配置。

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

- 自动检测并安装 nginx / openssl
- 自动生成自签 HTTPS 证书
- 自动创建 HTTP 跳转 HTTPS
- 交互选择前后端一致 / 前后端分离
- 自动生成 `/etc/nginx/conf.d/` 配置
- 覆盖旧配置前自动备份
- 执行 `nginx -t` 检查配置
- 自动 reload/restart nginx

## 注意

- 当前使用自签证书，浏览器首次访问会提示不受信任，手动继续访问即可。
- 证书默认保存在 `/etc/nginx/ssl/emby-reverse/`。
- 前后端分离模式内置了常见 Emby 推流、下载、WebSocket 路径；如有特殊路径，可手动编辑生成的 nginx 配置。
