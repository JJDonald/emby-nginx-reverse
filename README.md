# Emby Nginx Reverse Proxy 一键部署脚本

交互式管理 Emby 的 Nginx 反代配置，支持添加/更新和删除反代。添加反代时支持两种结构：

1. **前后端一致**：所有请求直接反代到同一个 Emby 地址。
2. **前后端分离**：Web/API 走前端地址，播放/推流/长连接路径走后端推流域名；后端推流域名支持填写多个，用英文逗号分隔。

脚本会先生成临时 HTTP 配置用于 Let’s Encrypt HTTP-01 验证，申请成功后自动切换到 HTTPS，并创建 HTTP -> HTTPS 跳转。

## 一键命令

```bash
curl -fsSL https://raw.githubusercontent.com/JJDonald/emby-nginx-reverse/main/deploy-emby-nginx-reverse.sh -o /tmp/deploy-emby-nginx-reverse.sh && sudo bash /tmp/deploy-emby-nginx-reverse.sh
```


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

- 反代管理菜单：添加/更新、删除
- 删除反代前自动备份 nginx 配置
- 删除反代时默认保留 Let’s Encrypt 证书，避免误删
- 自动检测并安装 nginx / certbot
- 自动申请 Let’s Encrypt 证书
- 自动创建 HTTP 跳转 HTTPS
- HTTPS 上游自动开启 SNI，兼容反代到 HTTPS 后端域名/CDN
- 交互选择前后端一致 / 前后端分离
- 前后端分离模式支持多个后端推流域名，按客户端和请求稳定分流
- 自动生成 `/etc/nginx/conf.d/` 配置
- 覆盖旧配置前自动备份
- 执行 `nginx -t` 检查配置
- 自动 reload/restart nginx

## 删除反代

再次运行脚本，选择 `删除反代`，脚本会列出 `/etc/nginx/conf.d/emby-*.conf` 中由本脚本创建的配置。确认后会备份并删除对应 nginx 配置，然后重载 nginx。

> 删除操作不会删除 Let’s Encrypt 证书。

## 注意

- Let’s Encrypt 不支持直接给 IP 签证书，必须使用域名。
- 证书默认保存在 `/etc/letsencrypt/live/<你的域名>/`。
- certbot 通常会自动安装续期定时任务，可用 `certbot renew --dry-run` 测试续期。
- 前后端分离模式内置了常见 Emby 推流、下载、WebSocket 路径；如有特殊路径，可手动编辑生成的 nginx 配置。
- 多个后端推流域名填写示例：`https://stream1.example.com,https://stream2.example.com:8920`。
- 当源站地址是 HTTPS 域名时，脚本会在反代配置中加入 `proxy_ssl_server_name on;`、`proxy_ssl_name $proxy_host;`，并把 `Host` 传给上游域名，避免上游 SNI/Host/证书不匹配。
