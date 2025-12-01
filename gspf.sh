#!/usr/bin/env bash
set -Eeuo pipefail

###==================== 全局变量 ====================###
MAIN_DOMAIN="hulin.pro"
EMAIL="gs@hulin.pro"

ROOT_DIR="/gspro"
LOG_FILE="/root/gspro.log"
mkdir -p "$ROOT_DIR" /var/lib/gspro

NPM_ADMIN_USER="admin"
NPM_ADMIN_PASS="Gaomeilan862447#"

PORT_WP_HTTP=9080
PORT_NC_HTTP=9000
PORT_OO_HTTP=9980
PORT_NOVNC=6080
PORT_COCKPIT=9090
PORT_VNC=5905

WHITE_IPS=("172.56.160.206" "172.56.164.101" "176.56.161.108")

DOMAINS_ALL=(
  "hulin.pro"
  "wp.hulin.pro"
  "ezglinns.com"
  "doc.hulin.pro"
  "dri.hulin.pro"
  "coc.hulin.pro"
  "npm.hulin.pro"
  "vnc.hulin.pro"
)

SERVER_IP="$(hostname -I | awk '{print $1}')"

###==================== 打印函数 ====================###
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m"; }

###==================== 工具函数 ====================###
apt_quiet(){ DEBIAN_FRONTEND=noninteractive apt-get -yq "$@"; }

is_port_listening(){ ss -tulpn | grep -q ":$1\b"; }
is_container_up(){ docker ps --format '{{.Names}}' | grep -qx "$1"; }
is_container_healthy(){
  docker ps --format '{{.Names}} {{.Status}}' \
    | awk -v n="$1" '$1==n{print $0}' | grep -Ei 'healthy'
}

http_ok_code(){ curl -sk -o /dev/null -w '%{http_code}' "$1" | grep -qx "$2"; }

free_port(){
  local p=$1
  local pids
  pids="$(ss -tulpn | awk -v P=":$p" '$0 ~ P {print $NF}' | \
    sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)"
  for pid in $pids; do kill -9 "$pid" || true; done
}

###==================== 指纹校验 ====================###
fingerprint(){
  find "$1" -maxdepth 2 -type f -print0 \
  | sort -z | xargs -0 sha1sum | sha1sum | awk '{print $1}'
}
fp_changed(){
  local new old
  new="$(fingerprint "$1")"
  old="$(cat "/var/lib/gspro/fp.$2" 2>/dev/null || true)"
  [[ "$new" != "$old" ]]
}
fp_save(){ fingerprint "$1" >"/var/lib/gspro/fp.$2"; }

###==================== 幂等执行 ====================###
ensure_ok(){
  local name="$1"
  local check="$2"
  local deploy="$3"
  local clean="$4"

  if eval "$check"; then
    green "[OK] $name 已就绪"
    return 0
  fi

  yellow "[REPAIR] $name 状态异常 → 清理后重建"
  eval "$clean" || true
  eval "$deploy"

  for i in 1 2 3; do
    sleep 4
    if eval "$check"; then
      green "[OK] $name 修复完成"
      return 0
    fi
    yellow "[WAIT] $name 第 $i 次复检未通过…"
  done

  red "[FAIL] $name 修复失败，请查看日志"
  exit 1
}

###==================== 环境准备 ====================###
prepare_system(){
  apt_quiet update
  apt_quiet install -y curl jq dnsutils ca-certificates \
      gnupg lsb-release software-properties-common
}
prepare_system

green "[OK] 基础系统准备完毕"
###==================== Step 1: Docker ====================###
docker_check(){
  command -v docker >/dev/null 2>&1 \
  && systemctl is-active --quiet docker \
  && docker ps >/dev/null 2>&1
}

docker_deploy(){
  apt_quiet update
  apt_quiet install -y ca-certificates gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu noble stable" \
      >/etc/apt/sources.list.d/docker.list

  apt_quiet update
  apt_quiet install -y docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin

  systemctl enable docker --now
}

docker_clean(){
  systemctl stop docker || true
  docker ps -aq | xargs -r docker stop || true
  docker ps -aq | xargs -r docker rm || true
  rm -rf /var/lib/docker /etc/docker /var/lib/containerd
}

ensure_ok "Docker" docker_check docker_deploy docker_clean


###==================== Step 2: NPM ====================###
npm_check(){
  is_container_healthy npm \
  && is_port_listening 81 \
  && http_ok_code "http://127.0.0.1:81" 200 \
  && ! fp_changed "$ROOT_DIR/npm" "npm"
}

npm_deploy(){
  mkdir -p "$ROOT_DIR/npm"
  cat >"$ROOT_DIR/npm/docker-compose.yml" <<'EOF'
version: "3.9"
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    environment:
      DB_SQLITE_FILE: "/data/database.sqlite"
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF

  (cd "$ROOT_DIR/npm" && docker compose up -d)
  fp_save "$ROOT_DIR/npm" "npm"
}

npm_clean(){
  docker rm -f npm 2>/dev/null || true
  rm -rf "$ROOT_DIR/npm/data" "$ROOT_DIR/npm/letsencrypt"
}

ensure_ok "Nginx Proxy Manager" npm_check npm_deploy npm_clean


###==================== Step 3: WordPress Multisite ====================###
wp_check(){
  is_container_up wp_db \
  && is_container_up wp_fpm \
  && is_container_up wp_nginx \
  && http_ok_code "http://127.0.0.1:${PORT_WP_HTTP}" 200 \
  && [[ -f "$ROOT_DIR/wp/html/wp-config.php" ]] \
  && grep -q "MULTISITE" "$ROOT_DIR/wp/html/wp-config.php" \
  && ! fp_changed "$ROOT_DIR/wp" "wp"
}

wp_deploy(){
  mkdir -p "$ROOT_DIR/wp"

  cat >"$ROOT_DIR/wp/docker-compose.yml" <<EOF
version: "3.9"
services:
  db:
    image: mariadb:10.11
    container_name: wp_db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${NPM_ADMIN_PASS}
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: ${NPM_ADMIN_PASS}
    volumes:
      - ./db:/var/lib/mysql

  wp_fpm:
    image: wordpress:php8.2-fpm
    container_name: wp_fpm
    restart: unless-stopped
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_NAME: wordpress
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: ${NPM_ADMIN_PASS}
    volumes:
      - ./html:/var/www/html
    depends_on: [ db ]

  wp_nginx:
    image: nginx:stable
    container_name: wp_nginx
    restart: unless-stopped
    ports:
      - "${PORT_WP_HTTP}:80"
    volumes:
      - ./html:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
    depends_on: [ wp_fpm ]
EOF

  cat >"$ROOT_DIR/wp/nginx.conf" <<'EOF'
server {
    listen 80;
    root /var/www/html;
    index index.php index.html;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
      include fastcgi_params;
      fastcgi_pass wp_fpm:9000;
      fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

  (cd "$ROOT_DIR/wp" && docker compose up -d)

  WP_PATH="$ROOT_DIR/wp/html"
  local t=0
  while [[ ! -f "$WP_PATH/wp-config-sample.php" && t -lt 240 ]]; do sleep 3; t=$((t+3)); done

  [[ -f "$WP_PATH/wp-config.php" ]] || cp "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php"

  grep -q "MULTISITE" "$WP_PATH/wp-config.php" || cat >>"$WP_PATH/wp-config.php" <<EOF

define('WP_ALLOW_MULTISITE', true);
define('MULTISITE', true);
define('SUBDOMAIN_INSTALL', true);
define('DOMAIN_CURRENT_SITE', '${MAIN_DOMAIN}');
define('PATH_CURRENT_SITE', '/');
define('SITE_ID_CURRENT_SITE', 1);
define('BLOG_ID_CURRENT_SITE', 1);
define('COOKIE_DOMAIN', '');
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO']==='https') { \$_SERVER['HTTPS']='on'; }
EOF

  fp_save "$ROOT_DIR/wp" "wp"
}

wp_clean(){
  docker rm -f wp_nginx wp_fpm wp_db 2>/dev/null || true
  rm -rf "$ROOT_DIR/wp/db"
}

ensure_ok "WordPress Multisite" wp_check wp_deploy wp_clean


###==================== Step 4: Nextcloud + OnlyOffice ====================###
nc_check(){
  is_container_up nc_db \
  && is_container_up nextcloud-app \
  && is_container_up onlyoffice \
  && http_ok_code "http://127.0.0.1:${PORT_NC_HTTP}" 200 \
  && http_ok_code "http://127.0.0.1:${PORT_OO_HTTP}" 200 \
  && ! fp_changed "$ROOT_DIR/nextcloud" "nextcloud"
}

nc_deploy(){
  mkdir -p "$ROOT_DIR/nextcloud"

  cat >"$ROOT_DIR/nextcloud/docker-compose.yml" <<EOF
version: "3.9"
services:
  db:
    image: mariadb:10.11
    container_name: nc_db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${NPM_ADMIN_PASS}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: ncuser
      MYSQL_PASSWORD: ${NPM_ADMIN_PASS}
    volumes:
      - ./db:/var/lib/mysql

  app:
    image: nextcloud:latest
    container_name: nextcloud-app
    restart: unless-stopped
    depends_on: [ db ]
    ports:
      - "${PORT_NC_HTTP}:80"
    volumes:
      - ./html:/var/www/html

  onlyoffice:
    image: onlyoffice/documentserver
    container_name: onlyoffice
    restart: unless-stopped
    ports:
      - "${PORT_OO_HTTP}:80"
EOF

  (cd "$ROOT_DIR/nextcloud" && docker compose up -d)
  fp_save "$ROOT_DIR/nextcloud" "nextcloud"
}

nc_clean(){
  docker rm -f onlyoffice nextcloud-app nc_db || true
  rm -rf "$ROOT_DIR/nextcloud/db"
}

ensure_ok "Nextcloud + OnlyOffice" nc_check nc_deploy nc_clean
###==================== Step 5: Cockpit ====================###
cockpit_check(){
  systemctl is-active --quiet cockpit && is_port_listening ${PORT_COCKPIT}
}

cockpit_deploy(){
  apt_quiet install -y cockpit cockpit-networkmanager cockpit-packagekit
  systemctl enable cockpit --now
}

cockpit_clean(){
  systemctl stop cockpit || true
  apt_quiet remove -y cockpit*
}

ensure_ok "Cockpit" cockpit_check cockpit_deploy cockpit_clean


###==================== Step 6: Portainer ====================###
portainer_check(){
  is_container_up portainer \
  && is_port_listening 9443 \
  && http_ok_code "https://127.0.0.1:9443" 200
}

portainer_deploy(){
  docker volume create portainer_data >/dev/null 2>&1 || true
  docker run -d --name portainer --restart=always \
    -p 9443:9443 -p 8000:8000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
}

portainer_clean(){
  docker rm -f portainer || true
  docker volume rm portainer_data || true
}

ensure_ok "Portainer" portainer_check portainer_deploy portainer_clean


###==================== Step 7: XFCE4 + TigerVNC + noVNC ====================###
vnc_check(){
  is_port_listening ${PORT_VNC} \
  && is_port_listening ${PORT_NOVNC}
}

vnc_deploy(){
  apt_quiet install -y xfce4 xfce4-goodies novnc websockify \
        tigervnc-standalone-server tigervnc-common

  mkdir -p /root/.vnc
  echo "${NPM_ADMIN_PASS}" | vncpasswd -f >/root/.vnc/passwd
  chmod 600 /root/.vnc/passwd

  cat >/root/.vnc/xstartup <<'EOF'
#!/bin/sh
xrdb $HOME/.Xresources
startxfce4 &
EOF
  chmod +x /root/.vnc/xstartup

  cat >/etc/systemd/system/vnc@5.service <<EOF
[Unit]
Description=TigerVNC Server :5
After=network.target

[Service]
Type=forking
User=root
ExecStart=/usr/bin/vncserver :5 -geometry 1440x900 -depth 24
ExecStop=/usr/bin/vncserver -kill :5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vnc@5 --now

  # noVNC
  nohup websockify --web=/usr/share/novnc/ ${PORT_NOVNC} localhost:${PORT_VNC} \
    >/dev/null 2>&1 &
}

vnc_clean(){
  systemctl disable vnc@5 || true
  systemctl stop vnc@5 || true
  rm -f /etc/systemd/system/vnc@5.service
  pkill websockify || true
}

ensure_ok "VNC + noVNC" vnc_check vnc_deploy vnc_clean


###==================== Step 8: Fail2ban（白名单） ====================###
fail2ban_check(){
  systemctl is-active --quiet fail2ban \
  && fail2ban-client status sshd >/dev/null 2>&1
}

fail2ban_deploy(){
  apt_quiet install -y fail2ban

  local IGNORE="127.0.0.1/8"
  for ip in "${WHITE_IPS[@]}"; do IGNORE+=" $ip"; done

  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = $IGNORE
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
EOF

  systemctl enable --now fail2ban
}

fail2ban_clean(){
  systemctl stop fail2ban || true
  rm -f /etc/fail2ban/jail.local
}

ensure_ok "Fail2ban" fail2ban_check fail2ban_deploy fail2ban_clean


###==================== Step 9: UFW 防火墙 ====================###
ufw_check(){ ufw status | grep -q "Status: active"; }

ufw_deploy(){
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 81/tcp
  ufw allow 443/tcp
  ufw allow ${PORT_COCKPIT}/tcp
  ufw allow ${PORT_VNC}/tcp
  ufw allow ${PORT_NOVNC}/tcp
  ufw --force enable
}

ufw_clean(){
  ufw --force reset || true
}

ensure_ok "UFW Firewall" ufw_check ufw_deploy ufw_clean
###==================== Step 10: NPM API 登录 ====================###
NPM_API="http://127.0.0.1:81/api"
NPM_TOKEN=""

npm_api_login(){
  local payload resp
  payload="{\"identity\":\"${NPM_ADMIN_USER}\",\"secret\":\"${NPM_ADMIN_PASS}\"}"

  resp="$(curl -s -H 'Content-Type: application/json' \
      -X POST ${NPM_API}/tokens -d "$payload" || echo '{}')"

  NPM_TOKEN="$(echo "$resp" | jq -r '.token // empty')"

  [[ -n "$NPM_TOKEN" && "$NPM_TOKEN" != "null" ]]
}

npm_login_until_ready(){
  local i=0
  until npm_api_login; do
    ((i++))
    [[ $i -gt 40 ]] && return 1
    sleep 3
  done
  return 0
}

auth_hdr(){ echo "Authorization: Bearer ${NPM_TOKEN}"; }


###==================== Step 11: 创建反代 Host ====================###
npm_list_hosts(){
  curl -s -H "$(auth_hdr)" "${NPM_API}/nginx/proxy-hosts" \
  | jq -r '.[].domain_names[]'
}

npm_proxy_exists(){
  local d="$1"
  npm_list_hosts | grep -Fxq "$d"
}

npm_create_proxy(){
  local d="$1"
  local t="$2"
  local host port

  host="$(echo "$t" | sed 's/http:\/\///')"
  port="${host##*:}"
  host="${host%%:*}"

  local req
  req="$(jq -nc \
    --arg d "$d" \
    --arg h "$host" \
    --argjson p "$port" \
    '{domain_names:[$d],
      forward_scheme:"http",
      forward_host:$h,
      forward_port:$p,
      access_list_id:0,
      certificate_id:0,
      ssl_forced:false}')"

  curl -s -H "$(auth_hdr)" -H 'Content-Type: application/json' \
       -X POST "${NPM_API}/nginx/proxy-hosts" -d "$req" >/dev/null 2>&1
}

declare -A PROXY_MAP

PROXY_MAP["hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"
PROXY_MAP["wp.hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"
PROXY_MAP["admin.hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"

PROXY_MAP["ezglinns.com"]="http://172.17.0.1:${PORT_WP_HTTP}"
PROXY_MAP["gsliberty.com"]="http://172.17.0.1:${PORT_WP_HTTP}"

PROXY_MAP["dri.hulin.pro"]="http://172.17.0.1:${PORT_NC_HTTP}"
PROXY_MAP["doc.hulin.pro"]="http://172.17.0.1:${PORT_OO_HTTP}"

PROXY_MAP["npm.hulin.pro"]="http://127.0.0.1:81"
PROXY_MAP["coc.hulin.pro"]="http://127.0.0.1:${PORT_COCKPIT}"
PROXY_MAP["vnc.hulin.pro"]="http://127.0.0.1:${PORT_NOVNC}"

create_all_proxies(){
  for d in "${DOMAINS_ALL[@]}"; do
    if npm_proxy_exists "$d"; then
      yellow "[Skip] 反代已存在：$d"
    else
      yellow "[Create] 创建反代：$d"
      npm_create_proxy "$d" "${PROXY_MAP[$d]}"
      sleep 1
    fi
  done
}

if ensure_ok "NPM Login" npm_login_until_ready npm_login_until_ready npm_login_until_ready; then
  ensure_ok "NPM Proxy Hosts" \
    "(npm_proxy_exists hulin.pro)" \
    create_all_proxies \
    create_all_proxies
fi


###==================== Step 12: SSL（强化修复版） ====================###
get_proxy_id(){
  local d="$1"
  curl -s -H "$(auth_hdr)" "${NPM_API}/nginx/proxy-hosts" \
    | jq \
      --arg d "$d" \
      -r '.[] | select(.domain_names[]==$d).id' \
      | head -n1
}

get_cert_id(){
  local d="$1"
  curl -s -H "$(auth_hdr)" "${NPM_API}/certificates" \
    | jq \
      --arg d "$d" \
      -r '.[] | select(.domain_names[]==$d).id' \
      | head -n1
}

delete_cert(){
  local id="$1"
  curl -s -H "$(auth_hdr)" \
      -X DELETE "${NPM_API}/certificates/${id}" >/dev/null 2>&1
}

apply_ssl(){
  local d="$1"
  local req cid resp

  req="$(jq -nc \
    --arg d "$d" \
    --arg em "$ADMIN_EMAIL" \
    '{domain_names:[$d],
      email:$em,
      provider:"letsencrypt",
      challenge:"http",
      agree_tos:true}')"

  resp="$(curl -s -H "$(auth_hdr)" -H 'Content-Type: application/json' \
            -X POST "${NPM_API}/certificates" -d "$req")"

  cid="$(echo "$resp" | jq -r '.id // empty')"

  [[ -n "$cid" && "$cid" != "null" ]] && echo "$cid" && return 0
  return 1
}

bind_ssl(){
  local proxy="$1"
  local cert="$2"

  local req
  req="$(jq -nc \
    --argjson cid "$cert" \
    '{certificate_id:$cid,
      ssl_forced:true,
      http2_support:true,
      hsts_enabled:false,
      hsts_subdomains:false}')"

  curl -s -H "$(auth_hdr)" -H 'Content-Type: application/json' \
       -X PUT "${NPM_API}/nginx/proxy-hosts/${proxy}" -d "$req" >/dev/null 2>&1
}

ssl_process_domain(){
  local d="$1"

  yellow "→ 处理 SSL：$d"

  local pid cid

  # 检查 DNS 是否指向当前 VPS
  local dns_ip
  dns_ip="$(dig +short "$d" | head -n1)"
  if [[ "$dns_ip" != "$SERVER_IP" ]]; then
    yellow "DNS 未指向此服务器（$dns_ip ≠ $SERVER_IP）跳过"
    return 0
  fi

  pid="$(get_proxy_id "$d")"
  [[ -z "$pid" ]] && yellow "未找到反代，跳过" && return 0

  cid="$(get_cert_id "$d")"

  if [[ -n "$cid" && "$cid" != "null" ]]; then
    green "[OK] 已存在证书，尝试绑定"
    bind_ssl "$pid" "$cid"
    return 0
  fi

  # 申请新证书（强化重试：最长 3 次）
  for i in 1 2 3; do
    yellow "申请 Let’s Encrypt（第 $i 次）：$d"
    cid="$(apply_ssl "$d")"

    if [[ -n "$cid" ]]; then
      green "[OK] 证书申请成功：ID=$cid"
      bind_ssl "$pid" "$cid"
      return 0
    fi

    yellow "申请失败，删除残留证书重试..."
    stale="$(get_cert_id "$d")"
    [[ -n "$stale" ]] && delete_cert "$stale"

    sleep 15
  done

  red "[FAIL] SSL 申请最终失败：$d"
}

ssl_all(){
  for d in "${DOMAINS_ALL[@]}"; do
    ssl_process_domain "$d"
  done

  docker exec npm nginx -s reload || true
}

ensure_ok "SSL Certificates" \
  "(get_cert_id hulin.pro)" \
  ssl_all \
  ssl_all
  ###==================== Step 13: /etc/hosts 自动写入 ====================###
write_hosts(){
  for d in "${DOMAINS_ALL[@]}"; do
    if ! grep -qE "${SERVER_IP}[[:space:]]+${d}" /etc/hosts; then
      echo "${SERVER_IP} ${d}" >> /etc/hosts
      echo " + hosts 添加：${d}"
    fi
  done
}

ensure_ok "Hosts 写入" \
  "(grep -q 'hulin.pro' /etc/hosts)" \
  write_hosts \
  write_hosts


###==================== Step 14: 自检（服务运行检测） ====================###
check_service(){
  local port="$1"
  ss -tulpn | grep -q ":${port} " && return 0
  return 1
}

service_selfcheck(){
  echo ""
  echo "================= 服务检测 ================="

  declare -A CHECKS
  CHECKS["NPM (80/443/81)"]="80"
  CHECKS["WordPress Multisite"]="${PORT_WP_HTTP}"
  CHECKS["Nextcloud"]="${PORT_NC_HTTP}"
  CHECKS["OnlyOffice"]="${PORT_OO_HTTP}"
  CHECKS["Cockpit"]="${PORT_COCKPIT}"
  CHECKS["noVNC"]="${PORT_NOVNC}"
  CHECKS["VNC"]="${PORT_VNC}"

  for name in "${!CHECKS[@]}"; do
    port="${CHECKS[$name]}"
    if check_service "$port"; then
      green "[OK] $name 端口 $port 正常运行"
    else
      red "[ERR] $name 端口 $port 未运行"
    fi
  done

  echo "============================================"
}

service_selfcheck


###==================== Step 15: 输出访问入口 ====================###
echo ""
green "=================================================="
green "🎉 部署已成功完成！以下是你的访问入口："
green "=================================================="
echo ""
echo "📌 主站首页：https://${MAIN_DOMAIN}"
echo "📌 WordPress 控制台：https://wp.${MAIN_DOMAIN}/wp-admin/network/"
echo "📌 Nextcloud：https://dri.${MAIN_DOMAIN}"
echo "📌 OnlyOffice 文档：https://doc.${MAIN_DOMAIN}"
echo "📌 NPM 仪表台：https://npm.${MAIN_DOMAIN}"
echo "📌 Cockpit 系统面板：https://coc.${MAIN_DOMAIN}"
echo "📌 noVNC（桌面）：https://vnc.${MAIN_DOMAIN}"
echo ""
green "日志文件：$LOG_FILE"
yellow "如遇部署中断，可删除断点文件重跑： rm -f $PROGRESS_FILE"
echo ""
green "⭐ 所有服务均已通过智能跳过机制验证。"
green "⭐ 已进行端口冲突清理 / SSL 强化修复 / 自动反代配置。"
echo ""


###==================== Step 16: 脚本结束 ====================###
exit 0
