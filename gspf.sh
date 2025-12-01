#!/usr/bin/env bash
set -Eeuo pipefail

###############################################
# GS-PRO FULL VPS DEPLOYER (IDEMPOTENT EDITION)
# Ubuntu 24.04 LTS ONLY
###############################################

### ========== 基础变量 ========== ###
MAIN_DOMAIN="hulin.pro"
EMAIL="gs@hulin.pro"

NPM_ADMIN_USER="admin"
NPM_ADMIN_PASS="Gaomeilan862447#"

SERVER_IP="$(hostname -I | awk '{print $1}')"

DOMAINS_ALL=(
  "hulin.pro"
  "wp.hulin.pro"
  "ezglinns.com"
  "gsliberty.com"
  "dri.hulin.pro"
  "doc.hulin.pro"
  "npm.hulin.pro"
  "coc.hulin.pro"
  "vnc.hulin.pro"
)

PORT_WP_HTTP=9080
PORT_NC_HTTP=9000
PORT_OO_HTTP=9980
PORT_COCKPIT=9090
PORT_NOVNC=6080
PORT_VNC=5905

WHITE_IPS=("172.56.160.206" "172.56.164.101" "176.56.161.108")

ROOT_DIR="/gspro"
LOG_FILE="/root/gspro.log"

exec > >(tee -a "$LOG_FILE") 2>&1

### ========== 打印工具 ========== ###
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m"; }

### ========== 幂等检查函数 ========== ###
container_ok() {
    docker ps --format '{{.Names}}' | grep -q "^$1$"
}

service_ok() {
    systemctl is-active "$1" >/dev/null 2>&1
}

port_open() {
    ss -tulpn | grep -q ":$1"
}

http_ok() {
    curl -sk -o /dev/null -w "%{http_code}" "$1" | grep -q "^200$"
}

### ========== 强制清理函数 ========== ###
clean_containers() {
    yellow "[清理] Docker 容器：$*"
    docker rm -f $* >/dev/null 2>&1 || true
}

clean_dir() {
    yellow "[清理] 目录：$1"
    rm -rf "$1" >/dev/null 2>&1 || true
}

free_port() {
    local PORT=$1
    if port_open "$PORT"; then
        PIDS=$(ss -tulpn | grep ":$PORT" | sed -E 's/.*pid=([0-9]+).*/\1/')
        for PID in $PIDS; do
            yellow "[释放端口] 杀死 PID $PID (端口 $PORT)"
            kill -9 "$PID" >/dev/null 2>&1 || true
        done
        sleep 1
    fi
}

### ========== 系统检查 ========== ###
green "[系统] 检查 root 权限"
if [[ $EUID -ne 0 ]]; then
  red "必须使用 root 执行"
  exit 1
fi

green "[系统] 检查 Ubuntu 版本"
grep -q "Ubuntu 24.04" /etc/os-release || {
  red "必须使用 Ubuntu 24.04 LTS"
  exit 1
}

### ========== Step 1：基础环境安装 ========== ###
green "[Step 1] 安装基础工具"
apt update -y
apt install -y ca-certificates curl jq gnupg lsb-release ufw dnsutils

### ========== Step 2：安装 Docker（幂等） ========== ###
green "[Step 2] 检查 Docker 是否已安装"

if service_ok docker; then
    green "[SKIP] Docker 已安装并运行"
else
    yellow "[安装] Docker"

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
"deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu noble stable" \
      >/etc/apt/sources.list.d/docker.list

    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable --now docker
    green "[OK] Docker 已安装并启动"
fi

### ========== Step 3：创建部署目录（幂等） ========== ###
green "[Step 3] 创建目录结构"
mkdir -p \
  "$ROOT_DIR" \
  "$ROOT_DIR/npm" \
  "$ROOT_DIR/wp" \
  "$ROOT_DIR/nextcloud" \
  "$ROOT_DIR/office" \
  "$ROOT_DIR/novnc" \
  "$ROOT_DIR/cockpit" \
  "$ROOT_DIR/portainer" \
  "$ROOT_DIR/personal" \
  "$ROOT_DIR/glinns" \
  "$ROOT_DIR/gsliberty"

green "[OK] 目录已准备好
###############################################
# ========== Step 4：部署 NPM（幂等） ==========
###############################################

green "[Step 4] 部署 Nginx Proxy Manager"

if container_ok npm && http_ok "http://127.0.0.1:81"; then
    green "[SKIP] NPM 已安装，且 Web 接口正常"
else
    yellow "[重新部署] 清理旧 NPM"
    clean_containers npm
    clean_dir "$ROOT_DIR/npm"

    mkdir -p "$ROOT_DIR/npm"
    cat > "$ROOT_DIR/npm/docker-compose.yml" <<EOF
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
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt"
EOF

    (cd "$ROOT_DIR/npm" && docker compose up -d)
    sleep 5
    green "[OK] 已启动 NPM"
fi


###############################################
# Step 5：部署 WordPress Multisite（幂等）
###############################################

green "[Step 5] 检查 WordPress Multisite"

if container_ok wp_db && container_ok wp_fpm && container_ok wp_nginx; then
    green "[SKIP] WordPress 容器存在"
else
    yellow "[重新部署] 清理 WordPress"
    clean_containers wp_db wp_fpm wp_nginx
    clean_dir "$ROOT_DIR/wp"

    mkdir -p "$ROOT_DIR/wp"
    cat > "$ROOT_DIR/wp/docker-compose.yml" <<EOF
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
    depends_on:
      - db

  wp_nginx:
    image: nginx:stable
    container_name: wp_nginx
    restart: unless-stopped
    ports:
      - "${PORT_WP_HTTP}:80"
    volumes:
      - ./html:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
    depends_on:
      - wp_fpm
EOF

    cat > "$ROOT_DIR/wp/nginx.conf" <<EOF
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass wp_fpm:9000;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

    (cd "$ROOT_DIR/wp" && docker compose up -d)
    green "[OK] 已启动 WordPress"
fi


###############################################
# Step 6：WordPress Multisite 配置（幂等）
###############################################

WP_PATH="$ROOT_DIR/wp/html"
if [[ -f "$WP_PATH/wp-config.php" ]] && grep -q "MULTISITE" "$WP_PATH/wp-config.php"; then
    green "[SKIP] WP Multisite 已配置"
else
    yellow "[配置] 写入 WordPress Multisite 参数"

    # 等待 WP HTML 生成
    t=0
    while [[ ! -f "$WP_PATH/wp-config-sample.php" && $t -lt 240 ]]; do
        sleep 3; t=$((t+3))
    done

    cp -n "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php" || true

    cat >> "$WP_PATH/wp-config.php" <<EOF

define( 'WP_ALLOW_MULTISITE', true );
define( 'MULTISITE', true );
define( 'SUBDOMAIN_INSTALL', true );
define( 'DOMAIN_CURRENT_SITE', '${MAIN_DOMAIN}' );
define( 'PATH_CURRENT_SITE', '/' );
define( 'SITE_ID_CURRENT_SITE', 1 );
define( 'BLOG_ID_CURRENT_SITE', 1 );
define( 'COOKIE_DOMAIN', '' );

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) 
    && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') { 
    \$_SERVER['HTTPS'] = 'on'; 
}
EOF

    green "[OK] WordPress Multisite 配置完成"
fi


###############################################
# Step 7：部署 Nextcloud + OnlyOffice（幂等）
###############################################

green "[Step 7] 检查 Nextcloud / OnlyOffice"

if container_ok nc_db && container_ok nextcloud-app && container_ok onlyoffice; then
    green "[SKIP] Nextcloud & OnlyOffice 已部署"
else
    yellow "[重新部署] 清理 Nextcloud / OnlyOffice"
    clean_containers nc_db nextcloud-app onlyoffice
    clean_dir "$ROOT_DIR/nextcloud"

    mkdir -p "$ROOT_DIR/nextcloud"
    cat > "$ROOT_DIR/nextcloud/docker-compose.yml" <<EOF
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
    depends_on: [db]
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
    green "[OK] Nextcloud + OnlyOffice 已启动"
fi


###############################################
# Step 8：Portainer（幂等）
###############################################

if container_ok portainer; then
    green "[SKIP] Portainer 已安装"
else
    yellow "[部署] Portainer"

    clean_containers portainer

    docker volume create portainer_data >/dev/null 2>&1 || true

    docker run -d \
      -p 9443:9443 \
      --name portainer \
      --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce

    green "[OK] Portainer 已启动"
fi


###############################################
# Step 9：Cockpit + VNC + noVNC（幂等）
###############################################

if service_ok cockpit; then
    green "[SKIP] Cockpit 已安装"
else
    apt install -y cockpit cockpit-networkmanager cockpit-packagekit
    systemctl enable --now cockpit
    green "[OK] Cockpit 已安装"
fi

if port_open "$PORT_VNC"; then
    green "[SKIP] VNC/noVNC 已运行"
else
    yellow "[部署] VNC + noVNC"

    apt install -y novnc websockify tigervnc-standalone-server xfce4 xfce4-goodies

    mkdir -p /root/.vnc
    echo "$NPM_ADMIN_PASS" | vncpasswd -f >/root/.vnc/passwd
    chmod 600 /root/.vnc/passwd

    cat > /root/.vnc/xstartup <<EOF
#!/bin/sh
xrdb \$HOME/.Xresources
startxfce4 &
EOF
    chmod +x /root/.vnc/xstartup

    cat > /etc/systemd/system/vnc@5.service <<EOF
[Unit]
Description=VNC Server :5
After=network.target

[Service]
Type=forking
User=root
ExecStart=/usr/bin/vncserver :5 -localhost no -geometry 1280x800 -depth 16
ExecStop=/usr/bin/vncserver -kill :5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now vnc@5

    nohup websockify --web=/usr/share/novnc/ ${PORT_NOVNC} localhost:${PORT_VNC} >/dev/null 2>&1 &
    green "[OK] noVNC 已启动"
fi


###############################################
# Step 10：Fail2ban + UFW
###############################################

green "[Step 10] 配置 Fail2ban + UFW"

apt install -y fail2ban

IGNORE_IPS="127.0.0.1/8"
for ip in "${WHITE_IPS[@]}"; do IGNORE_IPS+=" ${ip}"; done

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = ${IGNORE_IPS}
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF

systemctl enable --now fail2ban

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 81/tcp
ufw allow 443/tcp
ufw allow ${PORT_COCKPIT}/tcp
ufw allow ${PORT_VNC}/tcp
ufw allow ${PORT_NOVNC}/tcp
ufw --force enable

green "[OK] Fail2ban + UFW 已配置"
###############################################
# Step 11：NPM API 登录（自愈）
###############################################

green "[Step 11] 尝试登录 NPM API"

NPM_API="http://127.0.0.1:81/api"
TOKEN=""
npm_login() {
    local P="{\"identity\":\"$NPM_ADMIN_USER\",\"secret\":\"$NPM_ADMIN_PASS\"}"
    local R
    R="$(curl -s -H "Content-Type: application/json" -X POST "$NPM_API/tokens" -d "$P" || true)"
    TOKEN="$(echo "$R" | jq -r '.token // empty')"
    [[ -n "$TOKEN" && "$TOKEN" != "null" ]]
}

retry_login=0
until npm_login; do
    retry_login=$((retry_login+1))
    [[ $retry_login -gt 20 ]] && red "NPM 登录失败" && exit 1
    yellow "NPM 登录失败，等待 5 秒重试 ($retry_login/20)"
    sleep 5
done

green "[OK] 成功登录 NPM API"


###############################################
# 辅助函数：反代创建/检测
###############################################

proxy_id_by_domain() {
    curl -s -H "Authorization: Bearer $TOKEN" "$NPM_API/nginx/proxy-hosts" |
        jq ".[] | select(.domain_names[]==\"$1\") | .id" | head -n1
}

create_proxy() {
    local domain="$1"
    local url="$2"
    local h="$(echo "$url" | sed 's~http://~~; s~https://~~;')"
    local host="$(echo "$h" | cut -d: -f1)"
    local port="$(echo "$h" | cut -d: -f2)"

    local payload
    payload="$(jq -nc \
        --argjson dn "[\"$domain\"]" \
        --arg h "$host" \
        --argjson p "$port" '
    {
      domain_names: $dn,
      forward_scheme: "http",
      forward_host: $h,
      forward_port: ($p|tonumber),
      access_list_id: 0,
      certificate_id: 0,
      ssl_forced: false
    }'
    )"

    curl -s \
         -H "Authorization: Bearer $TOKEN" \
         -H "Content-Type: application/json" \
         -X POST "$NPM_API/nginx/proxy-hosts" \
         -d "$payload" >/dev/null 2>&1
}

###############################################
# Step 12：自动创建反代
###############################################

green "[Step 12] 创建反向代理（幂等）"

declare -A PROXY_MAP=(
    ["hulin.pro"]="http://172.17.0.1:$PORT_WP_HTTP"
    ["wp.hulin.pro"]="http://172.17.0.1:$PORT_WP_HTTP"
    ["ezglinns.com"]="http://172.17.0.1:$PORT_WP_HTTP"
    ["hulin.bz"]="http://172.17.0.1:$PORT_WP_HTTP"
    ["doc.hulin.pro"]="http://172.17.0.1:$PORT_OO_HTTP"
    ["dri.hulin.pro"]="http://172.17.0.1:$PORT_NC_HTTP"
    ["coc.hulin.pro"]="http://127.0.0.1:$PORT_COCKPIT"
    ["npm.hulin.pro"]="http://127.0.0.1:81"
    ["vnc.hulin.pro"]="http://127.0.0.1:$PORT_NOVNC"
)

for d in "${!PROXY_MAP[@]}"; do
    id="$(proxy_id_by_domain "$d")"
    if [[ -n "$id" ]]; then
        green "[SKIP] $d 已存在（ID=$id）"
        continue
    fi

    yellow "[创建] $d → ${PROXY_MAP[$d]}"
    create_proxy "$d" "${PROXY_MAP[$d]}"
    sleep 1
done


###############################################
# Step 13：SSL 申请（V4 自愈版本）
###############################################

green "[Step 13] 自动申请 SSL"

cert_id_by_domain() {
    curl -s -H "Authorization: Bearer $TOKEN" "$NPM_API/certificates" |
        jq ".[] | select(.domain_names[]==\"$1\") | .id" | head -n1
}

issue_cert() {
    local domain="$1"
    local payload
    payload="$(jq -nc \
        --argjson dn "[\"$domain\"]" \
        --arg em "$ADMIN_EMAIL" '
    {
      domain_names: $dn,
      email: $em,
      provider: "letsencrypt",
      challenge: "http",
      agree_tos: true
    }'
    )"

    curl -s \
         -H "Authorization: Bearer $TOKEN" \
         -H "Content-Type: application/json" \
         -X POST "$NPM_API/certificates" \
         -d "$payload"
}

bind_cert() {
    local pid="$1"
    local cid="$2"

    local payload
    payload="$(jq -nc \
        --argjson cid "$cid" '
    {
      certificate_id: $cid,
      ssl_forced: true,
      http2_support: true,
      hsts_enabled: false,
      hsts_subdomains: false
    }')"

    curl -s \
         -H "Authorization: Bearer $TOKEN" \
         -H "Content-Type: application/json" \
         -X PUT "$NPM_API/nginx/proxy-hosts/$pid" \
         -d "$payload" >/dev/null 2>&1
}


###############################################
# SSL 申请 + 绑定（每域名自愈 3 次）
###############################################

for d in "${!PROXY_MAP[@]}"; do
    echo ""
    green "[域名] $d"

    pid="$(proxy_id_by_domain "$d")"
    if [[ -z "$pid" ]]; then
        yellow "  ⚠ 未找到 proxy host，跳过"
        continue
    fi

    cid="$(cert_id_by_domain "$d")"
    if [[ -n "$cid" ]]; then
        green "  [SKIP] 已有证书 (ID=$cid)"
        bind_cert "$pid" "$cid"
        continue
    fi

    yellow "  [申请新证书] ($d)"

    attempts=0
    while (( attempts < 3 )); do
        Resp="$(issue_cert "$d")"
        cid="$(echo "$Resp" | jq -r '.id // empty')"

        if [[ -n "$cid" && "$cid" != "null" ]]; then
            green "  ✔ 成功：新证书 ID=$cid"
            bind_cert "$pid" "$cid"
            break
        fi

        attempts=$((attempts+1))
        yellow "  ✗ 失败，30 秒后重试 ($attempts/3)"
        sleep 30
    done

    [[ -z "$cid" ]] && red "  ❌ 证书创建失败：$d"
done

docker exec npm nginx -s reload || true
green "[OK] 所有 SSL 已绑定并重载 NPM"


###############################################
# Step 14：最终输出
###############################################

echo ""
green "=================================================="
green "        🎉 部署完成！GS-PRO Final 已就绪"
green "=================================================="

echo ""
green " 🌐 访问入口："
echo "   • 主站：https://$MAIN_DOMAIN"
echo "   • WordPress 管理：https://wp.$MAIN_DOMAIN/wp-admin"
echo "   • Nextcloud：https://dri.$MAIN_DOMAIN"
echo "   • OnlyOffice：https://doc.$MAIN_DOMAIN"
echo "   • NPM 控制台：https://npm.$MAIN_DOMAIN"
echo "   • Cockpit：https://coc.$MAIN_DOMAIN"
echo "   • VNC (noVNC)：https://vnc.$MAIN_DOMAIN"
echo ""

echo "日志文件：$LOG_FILE"
echo "断点文件：$PROGRESS_FILE"

green "完成！"
