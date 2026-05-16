#!/usr/bin/env bash
set -Eeuo pipefail

# Emby Nginx reverse proxy one-click deploy script
# - Mode 1: frontend/backend same origin: all requests proxy to one Emby address
# - Mode 2: frontend/backend separated: normal web/API requests proxy to frontend origin,
#           media streaming / websocket paths proxy to backend streaming origin
#
# Usage:
#   bash deploy-emby-nginx-reverse.sh
#
# Notes:
#   This script generates an HTTPS nginx server block with a self-signed certificate,
#   plus an HTTP -> HTTPS redirect server block.

SCRIPT_NAME="$(basename "$0")"
NGINX_CONF_DIR="/etc/nginx/conf.d"
BACKUP_DIR="/etc/nginx/emby-reverse-backups"
SSL_DIR="/etc/nginx/ssl/emby-reverse"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    red "请用 root 运行：sudo bash ${SCRIPT_NAME}"
    exit 1
  fi
}

install_packages_if_needed() {
  local need_nginx=0
  local need_openssl=0

  command -v nginx >/dev/null 2>&1 || need_nginx=1
  command -v openssl >/dev/null 2>&1 || need_openssl=1

  if [[ "${need_nginx}" -eq 0 ]]; then
    info "检测到 nginx 已安装：$(nginx -v 2>&1)"
  fi
  if [[ "${need_openssl}" -eq 0 ]]; then
    info "检测到 openssl 已安装"
  fi
  if [[ "${need_nginx}" -eq 0 && "${need_openssl}" -eq 0 ]]; then
    return
  fi

  yellow "开始安装缺失组件..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    [[ "${need_nginx}" -eq 1 ]] && apt-get install -y nginx
    [[ "${need_openssl}" -eq 1 ]] && apt-get install -y openssl
  elif command -v dnf >/dev/null 2>&1; then
    [[ "${need_nginx}" -eq 1 ]] && dnf install -y nginx
    [[ "${need_openssl}" -eq 1 ]] && dnf install -y openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    [[ "${need_nginx}" -eq 1 ]] && yum install -y nginx
    [[ "${need_openssl}" -eq 1 ]] && yum install -y openssl
  elif command -v apk >/dev/null 2>&1; then
    local packages=()
    [[ "${need_nginx}" -eq 1 ]] && packages+=(nginx)
    [[ "${need_openssl}" -eq 1 ]] && packages+=(openssl)
    apk add --no-cache "${packages[@]}"
  else
    red "无法识别包管理器，请先手动安装 nginx 和 openssl 后再运行本脚本。"
    exit 1
  fi
}

ensure_nginx_dirs() {
  mkdir -p "${NGINX_CONF_DIR}" "${BACKUP_DIR}" "${SSL_DIR}"

  # Some systems do not include conf.d/*.conf by default.
  if [[ -f /etc/nginx/nginx.conf ]] && ! grep -Eq 'include\s+/etc/nginx/conf\.d/\*\.conf;' /etc/nginx/nginx.conf; then
    yellow "注意：/etc/nginx/nginx.conf 里未发现 include /etc/nginx/conf.d/*.conf;"
    yellow "如果 nginx -t 失败或配置未生效，请手动确认 nginx 主配置是否包含 conf.d。"
  fi
}

trim_trailing_slash() {
  local value="$1"
  value="${value%/}"
  printf '%s' "$value"
}

read_required() {
  local prompt="$1"
  local value=""
  while [[ -z "${value}" ]]; do
    read -r -p "${prompt}" value
    value="$(echo "${value}" | xargs)"
  done
  printf '%s' "${value}"
}

read_optional_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  read -r -p "${prompt} [${default}]: " value
  value="$(echo "${value}" | xargs)"
  if [[ -z "${value}" ]]; then
    value="${default}"
  fi
  printf '%s' "${value}"
}

validate_origin() {
  local name="$1"
  local origin="$2"
  if [[ ! "${origin}" =~ ^https?://[^[:space:]]+$ ]]; then
    red "${name} 格式错误：${origin}"
    red "请使用完整地址，例如：http://127.0.0.1:8096 或 https://emby-backend.example.com"
    exit 1
  fi
}

write_common_proxy_headers() {
  cat <<'EOF'
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
EOF
}

generate_self_signed_cert() {
  local server_name="$1"
  local cert_path="$2"
  local key_path="$3"

  if [[ -f "${cert_path}" && -f "${key_path}" ]]; then
    info "检测到已有自签证书：${cert_path}"
    return
  fi

  info "生成自签 HTTPS 证书..."
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "${key_path}" \
    -out "${cert_path}" \
    -subj "/CN=${server_name}" \
    -addext "subjectAltName=DNS:${server_name},IP:127.0.0.1" >/dev/null 2>&1
  chmod 600 "${key_path}"
}

generate_same_config() {
  local server_name="$1"
  local http_port="$2"
  local https_port="$3"
  local cert_path="$4"
  local key_path="$5"
  local emby_origin="$6"

  cat <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen ${http_port};
    server_name ${server_name};
    return 301 https://\$host:${https_port}\$request_uri;
}

server {
    listen ${https_port} ssl http2;
    server_name ${server_name};

    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 0;

    location / {
$(write_common_proxy_headers)
        proxy_pass ${emby_origin};
    }
}
EOF
}

generate_split_config() {
  local server_name="$1"
  local http_port="$2"
  local https_port="$3"
  local cert_path="$4"
  local key_path="$5"
  local frontend_origin="$6"
  local backend_origin="$7"

  cat <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen ${http_port};
    server_name ${server_name};
    return 301 https://\$host:${https_port}\$request_uri;
}

server {
    listen ${https_port} ssl http2;
    server_name ${server_name};

    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 0;

    # 后端推流/长连接相关路径：走后端推流域名
    location ~* ^/(embywebsocket|socket|Videos|Audio|LiveTv|LiveStreams|Sync|emby/Videos|emby/Audio|emby/LiveTv|emby/LiveStreams|emby/Sync|Items/.*/Download|emby/Items/.*/Download) {
$(write_common_proxy_headers)
        proxy_pass ${backend_origin};
    }

    # 其它 Web 页面、静态资源和普通 API：走前端域名
    location / {
$(write_common_proxy_headers)
        proxy_pass ${frontend_origin};
    }
}
EOF
}

reload_nginx() {
  nginx -t

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx 2>/dev/null || systemctl restart nginx
  elif command -v service >/dev/null 2>&1; then
    service nginx reload 2>/dev/null || service nginx restart
  else
    nginx -s reload 2>/dev/null || nginx
  fi
}

main() {
  need_root
  install_packages_if_needed
  ensure_nginx_dirs

  echo ""
  green "=== Emby Nginx 反代一键部署 ==="
  echo "1) 前后端一致：所有请求直接反代到同一个 Emby 地址"
  echo "2) 前后端分离：Web/API 走前端地址，播放/推流走后端推流域名"
  echo ""

  local mode=""
  while [[ "${mode}" != "1" && "${mode}" != "2" ]]; do
    read -r -p "请选择结构 [1/2]: " mode
  done

  local server_name http_port https_port conf_name conf_path tmp_conf safe_name cert_path key_path
  server_name="$(read_required '请输入反代访问域名/IP，例如 emby.example.com 或 _: ')"
  http_port="$(read_optional_default '请输入 HTTP 跳转端口' '80')"
  https_port="$(read_optional_default '请输入 HTTPS 监听端口' '443')"
  safe_name="${server_name//[^A-Za-z0-9_.-]/_}"
  conf_name="emby-${safe_name}-${https_port}.conf"
  conf_path="${NGINX_CONF_DIR}/${conf_name}"
  cert_path="${SSL_DIR}/${safe_name}.crt"
  key_path="${SSL_DIR}/${safe_name}.key"
  tmp_conf="$(mktemp)"

  generate_self_signed_cert "${server_name}" "${cert_path}" "${key_path}"

  if [[ "${mode}" == "1" ]]; then
    local emby_origin
    emby_origin="$(read_required '请输入 Emby 源站地址，例如 http://127.0.0.1:8096: ')"
    emby_origin="$(trim_trailing_slash "${emby_origin}")"
    validate_origin "Emby 源站地址" "${emby_origin}"
    generate_same_config "${server_name}" "${http_port}" "${https_port}" "${cert_path}" "${key_path}" "${emby_origin}" > "${tmp_conf}"
  else
    local frontend_origin backend_origin
    frontend_origin="$(read_required '请输入前端源站地址，例如 http://127.0.0.1:8096: ')"
    backend_origin="$(read_required '请输入后端推流域名/地址，例如 https://stream.example.com 或 http://10.0.0.2:8096: ')"
    frontend_origin="$(trim_trailing_slash "${frontend_origin}")"
    backend_origin="$(trim_trailing_slash "${backend_origin}")"
    validate_origin "前端源站地址" "${frontend_origin}"
    validate_origin "后端推流域名/地址" "${backend_origin}"
    generate_split_config "${server_name}" "${http_port}" "${https_port}" "${cert_path}" "${key_path}" "${frontend_origin}" "${backend_origin}" > "${tmp_conf}"
  fi

  if [[ -f "${conf_path}" ]]; then
    local backup_path="${BACKUP_DIR}/${conf_name}.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "${conf_path}" "${backup_path}"
    yellow "已备份旧配置：${backup_path}"
  fi

  cp "${tmp_conf}" "${conf_path}"
  rm -f "${tmp_conf}"

  echo ""
  info "已写入配置：${conf_path}"
  info "开始测试并重载 nginx..."
  reload_nginx

  echo ""
  green "部署完成。"
  echo "访问地址：https://${server_name}:${https_port}"
  echo "HTTP 跳转：http://${server_name}:${http_port} -> HTTPS"
  echo "配置文件：${conf_path}"
  echo "证书文件：${cert_path}"
  echo "私钥文件：${key_path}"
  echo ""
  yellow "提示："
  echo "- 当前使用自签证书，浏览器首次访问会提示不受信任，手动继续访问即可。"
  echo "- 如果你前后端分离的推流路径有特殊规则，可编辑 ${conf_path} 里的后端 location 正则。"
}

main "$@"
