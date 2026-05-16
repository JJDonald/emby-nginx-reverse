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
#   This script generates an HTTP nginx server block first, obtains a Let's Encrypt
#   certificate with certbot webroot mode, then rewrites nginx to HTTPS with HTTP -> HTTPS redirect.

SCRIPT_NAME="$(basename "$0")"
NGINX_CONF_DIR="/etc/nginx/conf.d"
BACKUP_DIR="/etc/nginx/emby-reverse-backups"
ACME_WEBROOT="/var/www/letsencrypt"

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
  local need_certbot=0

  command -v nginx >/dev/null 2>&1 || need_nginx=1
  command -v certbot >/dev/null 2>&1 || need_certbot=1

  if [[ "${need_nginx}" -eq 0 ]]; then
    info "检测到 nginx 已安装：$(nginx -v 2>&1)"
  fi
  if [[ "${need_certbot}" -eq 0 ]]; then
    info "检测到 certbot 已安装"
  fi
  if [[ "${need_nginx}" -eq 0 && "${need_certbot}" -eq 0 ]]; then
    return
  fi

  yellow "开始安装缺失组件..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    [[ "${need_nginx}" -eq 1 ]] && apt-get install -y nginx
    [[ "${need_certbot}" -eq 1 ]] && apt-get install -y certbot
  elif command -v dnf >/dev/null 2>&1; then
    [[ "${need_nginx}" -eq 1 ]] && dnf install -y nginx
    [[ "${need_certbot}" -eq 1 ]] && dnf install -y certbot
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    [[ "${need_nginx}" -eq 1 ]] && yum install -y nginx
    [[ "${need_certbot}" -eq 1 ]] && yum install -y certbot
  elif command -v apk >/dev/null 2>&1; then
    local packages=()
    [[ "${need_nginx}" -eq 1 ]] && packages+=(nginx)
    [[ "${need_certbot}" -eq 1 ]] && packages+=(certbot)
    apk add --no-cache "${packages[@]}"
  else
    red "无法识别包管理器，请先手动安装 nginx 和 certbot 后再运行本脚本。"
    exit 1
  fi
}

ensure_nginx_dirs() {
  mkdir -p "${NGINX_CONF_DIR}" "${BACKUP_DIR}" "${ACME_WEBROOT}"

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

parse_backend_origins() {
  local raw="$1"
  local item=""
  BACKEND_ORIGINS=()

  IFS=',' read -ra items <<< "${raw}"
  for item in "${items[@]}"; do
    item="$(echo "${item}" | xargs)"
    [[ -z "${item}" ]] && continue
    item="$(trim_trailing_slash "${item}")"
    validate_origin "后端推流域名/地址" "${item}"
    BACKEND_ORIGINS+=("${item}")
  done

  if [[ "${#BACKEND_ORIGINS[@]}" -eq 0 ]]; then
    red "至少需要填写一个后端推流域名/地址。"
    exit 1
  fi
}

write_stream_backend_selector() {
  local origins=("$@")
  local count="${#origins[@]}"
  local i percent

  cat <<'EOF'
map $emby_stream_backend $emby_stream_backend_host {
    default $proxy_host;
    ~^https?://([^/:]+) $1;
}

map $emby_stream_backend $emby_stream_backend_host_header {
    default $proxy_host;
    ~^https?://([^/]+) $1;
}

EOF

  if [[ "${count}" -eq 1 ]]; then
    cat <<EOF
map \$request_uri \$emby_stream_backend {
    default ${origins[0]};
}
EOF
    return
  fi

  cat <<'EOF'
split_clients "${remote_addr}${request_uri}${http_user_agent}" $emby_stream_backend {
EOF
  for ((i = 0; i < count; i++)); do
    if [[ "${i}" -eq $((count - 1)) ]]; then
      printf '    * %s;\n' "${origins[$i]}"
    else
      percent=$((100 / count))
      printf '    %s%% %s;\n' "${percent}" "${origins[$i]}"
    fi
  done
  cat <<'EOF'
}
EOF
}

write_common_proxy_headers() {
  cat <<'EOF'
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_ssl_server_name on;
        proxy_ssl_name $proxy_host;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
EOF
}

validate_domain_for_letsencrypt() {
  local domain="$1"
  if [[ "${domain}" == "_" || "${domain}" =~ ^[0-9.]+$ || "${domain}" =~ : ]]; then
    red "Let's Encrypt 只能给公网域名签证书，不能使用 IP、_ 或带端口的 server_name：${domain}"
    exit 1
  fi
}

cert_path_for_domain() {
  printf '/etc/letsencrypt/live/%s/fullchain.pem' "$1"
}

key_path_for_domain() {
  printf '/etc/letsencrypt/live/%s/privkey.pem' "$1"
}

generate_http_config() {
  local server_name="$1"
  local http_port="$2"
  local origin="$3"

  cat <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen ${http_port};
    server_name ${server_name};

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }

    location / {
$(write_common_proxy_headers)
        proxy_set_header Host \$proxy_host;
        proxy_pass ${origin};
    }
}
EOF
}

obtain_letsencrypt_cert() {
  local domain="$1"
  local email="$2"
  local http_port="$3"

  if [[ -f "$(cert_path_for_domain "${domain}")" && -f "$(key_path_for_domain "${domain}")" ]]; then
    info "检测到已有 Let's Encrypt 证书：/etc/letsencrypt/live/${domain}/"
    return
  fi

  if [[ "${http_port}" != "80" ]]; then
    yellow "注意：HTTP-01 验证要求公网 80 端口可访问。当前 HTTP 端口为 ${http_port}，申请证书可能失败。"
  fi

  info "开始申请 Let's Encrypt 证书..."
  certbot certonly --webroot \
    -w "${ACME_WEBROOT}" \
    -d "${domain}" \
    --email "${email}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive
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

    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }

    client_max_body_size 0;

    location / {
$(write_common_proxy_headers)
        proxy_set_header Host \$proxy_host;
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
  shift 6
  local backend_origins=("$@")

  cat <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

$(write_stream_backend_selector "${backend_origins[@]}")

server {
    listen ${http_port};
    server_name ${server_name};
    return 301 https://\$host:${https_port}\$request_uri;
}

server {
    listen ${https_port} ssl http2;
    server_name ${server_name};

    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    ssl_certificate ${cert_path};
    ssl_certificate_key ${key_path};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    location /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
    }

    client_max_body_size 0;

    # 后端推流/长连接相关路径：走后端推流域名；多个后端会按客户端和请求稳定分流
    location ~* ^/(embywebsocket|socket|Videos|Audio|LiveTv|LiveStreams|Sync|emby/Videos|emby/Audio|emby/LiveTv|emby/LiveStreams|emby/Sync|Items/.*/Download|emby/Items/.*/Download) {
$(write_common_proxy_headers)
        proxy_set_header Host \$emby_stream_backend_host_header;
        proxy_ssl_name \$emby_stream_backend_host;
        proxy_pass \$emby_stream_backend;
    }

    # 其它 Web 页面、静态资源和普通 API：走前端域名
    location / {
$(write_common_proxy_headers)
        proxy_set_header Host \$proxy_host;
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

list_reverse_configs() {
  local files=("$@")
  local index=1

  echo ""
  green "=== 已有 Emby 反代配置 ==="
  for file in "${files[@]}"; do
    printf '%s) %s\n' "${index}" "${file}"
    index=$((index + 1))
  done
}

delete_reverse_proxy() {
  shopt -s nullglob
  local files=("${NGINX_CONF_DIR}"/emby-*.conf)
  shopt -u nullglob

  if [[ "${#files[@]}" -eq 0 ]]; then
    yellow "没有找到由本脚本创建的 Emby 反代配置：${NGINX_CONF_DIR}/emby-*.conf"
    return
  fi

  list_reverse_configs "${files[@]}"

  local choice=""
  while true; do
    read -r -p "请选择要删除的配置编号，或输入 q 取消: " choice
    if [[ "${choice}" == "q" || "${choice}" == "Q" ]]; then
      yellow "已取消删除。"
      return
    fi
    if [[ "${choice}" =~ ^[0-9]+$ && "${choice}" -ge 1 && "${choice}" -le "${#files[@]}" ]]; then
      break
    fi
    red "输入无效，请重新选择。"
  done

  local target="${files[$((choice - 1))]}"
  local confirm=""
  echo ""
  yellow "即将删除反代配置：${target}"
  yellow "证书不会删除，只删除 nginx 反代配置。"
  read -r -p "确认删除？输入 y 继续: " confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    yellow "已取消删除。"
    return
  fi

  local backup_path="${BACKUP_DIR}/$(basename "${target}").$(date +%Y%m%d-%H%M%S).deleted.bak"
  cp -a "${target}" "${backup_path}"
  rm -f "${target}"

  info "已备份被删除配置：${backup_path}"
  info "开始测试并重载 nginx..."
  reload_nginx
  green "删除完成。"
}

add_or_update_reverse_proxy() {
  echo ""
  green "=== 添加/更新 Emby Nginx 反代 ==="
  echo "1) 前后端一致：所有请求直接反代到同一个 Emby 地址"
  echo "2) 前后端分离：Web/API 走前端地址，播放/推流走后端推流域名"
  echo ""

  local mode=""
  while [[ "${mode}" != "1" && "${mode}" != "2" ]]; do
    read -r -p "请选择结构 [1/2]: " mode
  done

  local server_name http_port https_port email conf_name conf_path tmp_conf safe_name cert_path key_path primary_origin
  local -a BACKEND_ORIGINS=()
  server_name="$(read_required '请输入反代访问域名，例如 emby.example.com: ')"
  validate_domain_for_letsencrypt "${server_name}"
  email="$(read_required '请输入申请 Let’s Encrypt 证书用的邮箱: ')"
  http_port="$(read_optional_default '请输入 HTTP 端口，Let’s Encrypt 推荐/要求公网 80' '80')"
  https_port="$(read_optional_default '请输入 HTTPS 监听端口' '443')"
  safe_name="${server_name//[^A-Za-z0-9_.-]/_}"
  conf_name="emby-${safe_name}-${https_port}.conf"
  conf_path="${NGINX_CONF_DIR}/${conf_name}"
  cert_path="$(cert_path_for_domain "${server_name}")"
  key_path="$(key_path_for_domain "${server_name}")"
  tmp_conf="$(mktemp)"

  if [[ "${mode}" == "1" ]]; then
    local emby_origin
    emby_origin="$(read_required '请输入 Emby 源站地址，例如 http://127.0.0.1:8096: ')"
    emby_origin="$(trim_trailing_slash "${emby_origin}")"
    validate_origin "Emby 源站地址" "${emby_origin}"
    primary_origin="${emby_origin}"
  else
    local frontend_origin backend_origin_raw
    frontend_origin="$(read_required '请输入前端源站地址，例如 http://127.0.0.1:8096: ')"
    backend_origin_raw="$(read_required '请输入后端推流域名/地址，多个用英文逗号分隔，例如 https://stream1.example.com,https://stream2.example.com: ')"
    frontend_origin="$(trim_trailing_slash "${frontend_origin}")"
    validate_origin "前端源站地址" "${frontend_origin}"
    parse_backend_origins "${backend_origin_raw}"
    primary_origin="${frontend_origin}"
  fi

  if [[ -f "${conf_path}" ]]; then
    local backup_path="${BACKUP_DIR}/${conf_name}.$(date +%Y%m%d-%H%M%S).bak"
    cp -a "${conf_path}" "${backup_path}"
    yellow "已备份旧配置：${backup_path}"
  fi

  generate_http_config "${server_name}" "${http_port}" "${primary_origin}" > "${tmp_conf}"
  cp "${tmp_conf}" "${conf_path}"
  echo ""
  info "已写入临时 HTTP 配置：${conf_path}"
  info "开始测试并重载 nginx，用于 Let’s Encrypt HTTP-01 验证..."
  reload_nginx

  obtain_letsencrypt_cert "${server_name}" "${email}" "${http_port}"

  if [[ "${mode}" == "1" ]]; then
    generate_same_config "${server_name}" "${http_port}" "${https_port}" "${cert_path}" "${key_path}" "${primary_origin}" > "${tmp_conf}"
  else
    generate_split_config "${server_name}" "${http_port}" "${https_port}" "${cert_path}" "${key_path}" "${frontend_origin}" "${BACKEND_ORIGINS[@]}" > "${tmp_conf}"
  fi

  cp "${tmp_conf}" "${conf_path}"
  rm -f "${tmp_conf}"

  echo ""
  info "已写入 HTTPS 配置：${conf_path}"
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
  echo "- Let’s Encrypt HTTP-01 验证需要域名 A/AAAA 记录指向本机，且公网 80 端口可访问。"
  echo "- certbot 通常会自动安装续期定时任务；可用 certbot renew --dry-run 测试续期。"
  echo "- 如果你前后端分离的推流路径有特殊规则，可编辑 ${conf_path} 里的后端 location 正则。"
}

main() {
  need_root
  install_packages_if_needed
  ensure_nginx_dirs

  echo ""
  green "=== Emby Nginx 反代管理 ==="
  echo "1) 添加/更新反代"
  echo "2) 删除反代"
  echo ""

  local action=""
  while [[ "${action}" != "1" && "${action}" != "2" ]]; do
    read -r -p "请选择操作 [1/2]: " action
  done

  case "${action}" in
    1) add_or_update_reverse_proxy ;;
    2) delete_reverse_proxy ;;
  esac
}

main "$@"
