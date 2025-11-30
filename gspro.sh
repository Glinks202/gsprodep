#!/bin/bash
##########################################################################
# GS-PRO — 全自动云基础设施部署脚本（含断点恢复）
# Version: FINAL-2025-STABLE
# Author: GLINKS
##########################################################################

set -e

# -------------------- 颜色 --------------------
GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" && exit 1; }

# -------------------- 断点记录文件 --------------------
PROGRESS_FILE="/root/.gspro-progress"

# -------------------- 断点恢复函数 --------------------
step(){
    local STEP_NUM="$1"
    local STEP_NAME="$2"

    if [ -f "$PROGRESS_FILE" ]; then
        LAST=$(cat "$PROGRESS_FILE")
        if (( STEP_NUM <= LAST )); then
            warn "跳过 Step $STEP_NUM：$STEP_NAME（已完成）"
            return 1
        fi
    fi

    echo "$STEP_NUM" > "$PROGRESS_FILE"
    ok "开始 Step $STEP_NUM：$STEP_NAME"
    return 0
}

##########################################################################
# Step 0 — 基础环境检查
##########################################################################
step 0 "基础环境检查" || true

# 必须 root
if [[ $EUID -ne 0 ]]; then
    err "必须使用 root 权限运行！"
fi

# 必须 Ubuntu 24.04
if ! grep -q "Ubuntu 24.04" /etc/os-release; then
    err "此脚本仅支持 Ubuntu 24.04 LTS"
fi
ok "系统版本正确：Ubuntu 24.04 LTS"

# 自动获取服务器真实 IP
SERVER_IP=$(hostname -I | awk '{print $1}')
ok "自动检测服务器 IP：$SERVER_IP"

# 常用变量
MAIN_DOMAIN="hulin.pro"
ADMIN_EMAIL="gs@hulin.pro"

# NPM 登录信息
NPM_USER="admin"
NPM_PASS="Gaomeilan862447#"

# VNC 密码
VNC_PASS="862447"

# SFTP 密码
PW_ADMIN="862447"
PW_STAFF="862446"
PW_SUPPORT="862445"
PW_BILLING="862444"

ok "基础变量加载完成"

##########################################################################
# Step 1 — 清理旧环境
##########################################################################
step 1 "清理旧环境：Docker / Apache / 旧反代" || true

systemctl stop apache2 >/dev/null 2>&1 || true
systemctl disable apache2 >/dev/null 2>&1 || true
apt remove -y apache2* >/dev/null 2>&1 || true

apt remove -y docker docker.io docker-engine containerd runc >/dev/null 2>&1 || true
rm -rf /var/lib/docker /var/lib/containerd /etc/docker

ok "旧环境清理完成（安全）"

##########################################################################
# Step 2 — 更新系统
##########################################################################
step 2 "系统更新 & 依赖安装" || true

apt update -y
apt upgrade -y
apt install -y ca-certificates curl gnupg lsb-release jq ufw lsof

ok "系统更新完成"
##########################################################################
# Step 3 — 安装 Docker (最新版本)
##########################################################################
step 3 "安装 Docker" || true

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
 | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
 https://download.docker.com/linux/ubuntu noble stable" \
 | tee /etc/apt/sources.list.d/docker.list >/dev/null

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl restart docker

ok "Docker 安装完成"


##########################################################################
# Step 4 — GSPro 目录结构
##########################################################################
step 4 "创建 /gspro 目录结构" || true

mkdir -p /gspro/{npm,wp,nextcloud,office,novnc,portainer,cockpit,config,ssl,logs}

ok "目录结构创建完成"


##########################################################################
# Step 5 — 部署 Nginx Proxy Manager (NPM)
##########################################################################
step 5 "部署 Nginx Proxy Manager" || true

cat >/gspro/npm/docker-compose.yml <<EOF
version: "3.8"
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

cd /gspro/npm
docker compose up -d

ok "NPM 已启动：80 / 81 / 443"


##########################################################################
# Step 6 — 安装 noVNC + VNC 图形桌面
##########################################################################
step 6 "部署 noVNC + VNC 图形桌面" || true

apt install -y novnc websockify xfce4 xfce4-terminal tigervnc-standalone-server

mkdir -p /gspro/novnc
cat >/gspro/novnc/start.sh <<EOF
#!/bin/bash
vncserver -kill :1 >/dev/null 2>&1
vncserver :1 -geometry 1280x800 -depth 16 -SecurityTypes None
websockify --web=/usr/share/novnc/ 6080 localhost:5901
EOF

chmod +x /gspro/novnc/start.sh

ok "noVNC 已准备完成（Web: :6080）"


##########################################################################
# Step 7 — 安装 Cockpit（系统管理面板）
##########################################################################
step 7 "安装 Cockpit 管理面板" || true

apt install -y cockpit cockpit-networkmanager cockpit-storaged cockpit-packagekit

systemctl enable cockpit
systemctl restart cockpit

ok "Cockpit 已启动：9090"


##########################################################################
# Step 8 — 部署 Portainer（Docker 可视化管理）
##########################################################################
step 8 "部署 Portainer" || true

docker volume create portainer_data

docker run -d \
    -p 9443:9443 \
    -p 8000:8000 \
    --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest

ok "Portainer 已启动：9443"
##########################################################################
# Step 9 — 部署 Nextcloud + OnlyOffice
##########################################################################
step 9 "部署 Nextcloud + OnlyOffice" || true

mkdir -p /gspro/nextcloud
cd /gspro/nextcloud

cat >docker-compose.yml <<EOF
version: '3.8'

services:
  nc_db:
    image: mariadb:10.11
    restart: always
    container_name: nc_db
    environment:
      MYSQL_ROOT_PASSWORD: $NPM_PASS
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: ncuser
      MYSQL_PASSWORD: $NPM_PASS
    volumes:
      - ./db:/var/lib/mysql

  nextcloud:
    image: nextcloud:latest
    container_name: nextcloud_app
    restart: always
    depends_on:
      - nc_db
    ports:
      - 9000:80
    volumes:
      - ./html:/var/www/html

  onlyoffice:
    image: onlyoffice/documentserver
    container_name: onlyoffice
    restart: always
    ports:
      - 9980:80
EOF

docker compose up -d

ok "Nextcloud + OnlyOffice 容器已启动"


##########################################################################
# Step 10 — 部署 WordPress 多站点（Multisite）
##########################################################################
step 10 "部署 WordPress 多站点" || true

mkdir -p /gspro/wp
cd /gspro/wp

cat >docker-compose.yml <<EOF
version: '3.8'

services:
  wp_db:
    image: mariadb:10.11
    container_name: wp_db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $NPM_PASS
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: $NPM_PASS
    volumes:
      - ./db:/var/lib/mysql

  wp_fpm:
    image: wordpress:php8.2-fpm
    container_name: wp_fpm
    restart: always
    depends_on:
      - wp_db
    environment:
      WORDPRESS_DB_HOST: wp_db
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: $NPM_PASS
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - ./html:/var/www/html

  wp_nginx:
    image: nginx
    container_name: wp_nginx
    restart: always
    ports:
      - 9080:80
    volumes:
      - ./html:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
EOF

cat >nginx.conf <<EOF
server {
    listen 80;
    root /var/www/html;
    index index.php index.html;
    server_name _;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        fastcgi_pass wp_fpm:9000;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

docker compose up -d

ok "WordPress 多站点容器已启动 (9080)"


##########################################################################
# Step 11 — WordPress 多站点配置（自动修改 wp-config.php）
##########################################################################
step 11 "配置 WordPress Multisite" || true

WP_PATH="/gspro/wp/html"

# 等待 WordPress 初始化文件
until [ -f "$WP_PATH/wp-config-sample.php" ]; do
    yellow "等待 WordPress 初始化中..."
    sleep 5
done

cp "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php"

cat >>"$WP_PATH/wp-config.php" <<EOF

/** Multisite 开启 */
define( 'WP_ALLOW_MULTISITE', true );
define( 'MULTISITE', true );
define( 'SUBDOMAIN_INSTALL', true );

define( 'DOMAIN_CURRENT_SITE', '$MAIN_DOMAIN' );
define( 'PATH_CURRENT_SITE', '/' );
define( 'SITE_ID_CURRENT_SITE', 1 );
define( 'BLOG_ID_CURRENT_SITE', 1 );

// 修复反代 HTTPS
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
EOF

ok "wp-config.php 已写入多站点配置"


##########################################################################
# Step 12 — 自动写入 WordPress 子域名（Hosts）
##########################################################################
step 12 "写入 WordPress 子域名 hosts" || true

HOSTS_LIST="
$MAIN_DOMAIN
wp.$MAIN_DOMAIN
admin.$MAIN_DOMAIN
doc.$MAIN_DOMAIN
dri.$MAIN_DOMAIN
npm.$MAIN_DOMAIN
vnc.$MAIN_DOMAIN
coc.$MAIN_DOMAIN
"

for h in $HOSTS_LIST; do
    if ! grep -q "$h" /etc/hosts; then
        echo "$SERVER_IP  $h" >> /etc/hosts
        echo " + hosts 添加：$h"
    fi
done

ok "/etc/hosts 已更新"
##########################################################################
# Step 13 — 自动创建 NPM 反代（使用 API）
##########################################################################
step 13 "创建 NPM 反代配置" || true

AUTH="Authorization: Basic $(echo -n "${NPM_USER}:${NPM_PASS}" | base64)"
NPM_API="http://127.0.0.1:81/api"

declare -A SERVICES
SERVICES=(
  ["$MAIN_DOMAIN"]="http://172.17.0.1:9080"
  ["wp.$MAIN_DOMAIN"]="http://172.17.0.1:9080"
  ["admin.$MAIN_DOMAIN"]="http://172.17.0.1:9080/wp-admin/network/"
  ["doc.$MAIN_DOMAIN"]="http://172.17.0.1:9980"
  ["dri.$MAIN_DOMAIN"]="http://172.17.0.1:9000"
  ["coc.$MAIN_DOMAIN"]="http://127.0.0.1:9090"
  ["npm.$MAIN_DOMAIN"]="http://127.0.0.1:81"
  ["vnc.$MAIN_DOMAIN"]="http://127.0.0.1:6080"
)

create_proxy_host(){
    local domain="$1"
    local TARGET="$2"

    FORWARD_HOST=$(echo "$TARGET" | sed 's~http://~~' | cut -d: -f1)
    FORWARD_PORT=$(echo "$TARGET" | sed 's~http://~~' | cut -d: -f2)

    REQ=$(cat <<EOF
{
  "domain_names": ["$domain"],
  "forward_scheme": "http",
  "forward_host": "$FORWARD_HOST",
  "forward_port": $FORWARD_PORT,
  "access_list_id": 0,
  "certificate_id": 0,
  "ssl_forced": false
}
EOF
)

    curl -s -X POST "$NPM_API/nginx/proxy-hosts" \
        -H "$AUTH" -H "Content-Type: application/json" \
        -d "$REQ" >/dev/null
}

echo "📌 开始批量创建 NPM 反代..."
sleep 3

for domain in "${!SERVICES[@]}"; do
    echo " → 创建反代：$domain"
    create_proxy_host "$domain" "${SERVICES[$domain]}"
done

ok "所有反代创建完毕"


##########################################################################
# Step 14 — 自动申请 SSL（Let's Encrypt）
##########################################################################
step 14 "申请 SSL 证书（所有域名）" || true

# 自动 DNS 对比：使用 $SERVER_IP，不再写死
dns_ok(){
    TARGET_IP=$(dig +short "$1" | head -n1)
    [[ "$TARGET_IP" == "$SERVER_IP" ]]
}

# 获取 proxy host ID
get_host_id(){
    curl -s -H "$AUTH" "$NPM_API/nginx/proxy-hosts" \
    | jq ".[] | select(.domain_names[]==\"$1\") | .id"
}

# 创建 LE 证书
create_cert(){
    local DOMAIN="$1"
    REQ=$(cat <<EOF
{
  "domain_names": ["$DOMAIN"],
  "email": "$EMAIL_ADMIN",
  "provider": "letsencrypt",
  "challenge": "http",
  "agree_tos": true
}
EOF
)
    curl -s -X POST "$NPM_API/certificates" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "$REQ"
}

# 绑定证书
bind_cert(){
    local HID="$1"
    local CID="$2"
    REQ=$(cat <<EOF
{
  "certificate_id": $CID,
  "ssl_forced": true,
  "http2_support": true,
  "hsts_enabled": false
}
EOF
)
    curl -s -X PUT "$NPM_API/nginx/proxy-hosts/$HID" \
        -H "$AUTH" -H "Content-Type: application/json" \
        -d "$REQ" >/dev/null
}

SSL_LIST="
$MAIN_DOMAIN
wp.$MAIN_DOMAIN
admin.$MAIN_DOMAIN
doc.$MAIN_DOMAIN
dri.$MAIN_DOMAIN
npm.$MAIN_DOMAIN
vnc.$MAIN_DOMAIN
coc.$MAIN_DOMAIN
"

echo "📌 开始批量申请 SSL..."

for DOMAIN in $SSL_LIST; do
    echo ""
    echo "▶︎ 域名：$DOMAIN"

    if ! dns_ok "$DOMAIN"; then
        yellow " ✗ DNS 未指向 $SERVER_IP，跳过"
        continue
    fi

    echo " ✓ DNS 正确"

    HID=$(get_host_id "$DOMAIN")
    if [[ -z "$HID" ]]; then
        yellow "未找到 Proxy Host，重试中..."
        sleep 8
        HID=$(get_host_id "$DOMAIN")
    fi

    if [[ -z "$HID" ]]; then
        red "无法匹配 Host ID，跳过 $DOMAIN"
        continue
    fi

    echo " → Proxy Host ID: $HID"
    echo " → 创建证书中..."

    RES=$(create_cert "$DOMAIN")
    CID=$(echo "$RES" | jq -r ".id")

    if [[ "$CID" == "null" || -z "$CID" ]]; then
        yellow "第一次失败，等待 60 秒再试..."
        sleep 60
        RES=$(create_cert "$DOMAIN")
        CID=$(echo "$RES" | jq -r ".id")
    fi

    if [[ "$CID" == "null" || -z "$CID" ]]; then
        red "证书失败，跳过"
        continue
    fi

    bind_cert "$HID" "$CID"
    echo " ✓ SSL 已绑定"
done

ok "所有 SSL 流程完成"

# 重载 NPM
docker exec npm nginx -s reload || true
ok "NPM 重载完成（SSL 生效）"
##########################################################################
# Step 15 — Fail2ban 安装 + 自动配置（含白名单）
##########################################################################
step 15 "安装 Fail2ban + 加入 IP 白名单" || true

apt install -y fail2ban

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
EOF

systemctl restart fail2ban
systemctl enable fail2ban

ok "Fail2ban 已安装 + 默认白名单已加入"


##########################################################################
# Step 16 — UFW 防火墙规则
##########################################################################
step 16 "防火墙 UFW 规则" || true

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 5905/tcp      # VNC
ufw allow 6080/tcp      # noVNC
ufw allow 9090/tcp      # Cockpit

ufw --force enable

ok "UFW 已启用 + 所有端口规则写入"


##########################################################################
# Step 17 — 安装 VNC Server + 图形桌面 XFCE
##########################################################################
step 17 "安装 VNC Server + XFCE 桌面" || true

apt install -y xfce4 xfce4-goodies tightvncserver x11-xserver-utils

# 初始化 VNC 密码
mkdir -p /root/.vnc
echo "${VNC_PASS}" | vncpasswd -f >/root/.vnc/passwd
chmod 600 /root/.vnc/passwd

cat >/root/.vnc/xstartup <<EOF
#!/bin/sh
xrdb \$HOME/.Xresources
startxfce4 &
EOF
chmod +x /root/.vnc/xstartup

# 测试启动一次
vncserver :5
vncserver -kill :5

# systemd 自启
cat >/etc/systemd/system/vnc@5.service <<EOF
[Unit]
Description=VNC Server :5
After=syslog.target network.target

[Service]
Type=forking
ExecStart=/usr/bin/vncserver :5
ExecStop=/usr/bin/vncserver -kill :5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vnc@5
systemctl restart vnc@5

ok "VNC 服务已启动 → 端口 5905"


##########################################################################
# Step 18 — 安装 noVNC（网页图形桌面）
##########################################################################
step 18 "安装 noVNC" || true

apt install -y novnc websockify

# 启动 noVNC 映射
websockify -D --web=/usr/share/novnc/ 6080 localhost:5905

ok "noVNC 已启动 → https://vnc.$MAIN_DOMAIN"


##########################################################################
# Step 19 — /etc/hosts 自动写入所有域名
##########################################################################
step 19 "写入 /etc/hosts（自动使用 SERVER_IP）" || true

HOSTS_LIST="
$MAIN_DOMAIN
wp.$MAIN_DOMAIN
admin.$MAIN_DOMAIN
doc.$MAIN_DOMAIN
dri.$MAIN_DOMAIN
npm.$MAIN_DOMAIN
vnc.$MAIN_DOMAIN
coc.$MAIN_DOMAIN
"

for h in $HOSTS_LIST; do
    if ! grep -q "$h" /etc/hosts; then
        echo "$SERVER_IP  $h" >> /etc/hosts
        echo " → hosts 加入：$SERVER_IP  $h"
    fi
done

ok "/etc/hosts 更新完成（全部使用 \$SERVER_IP）"
##########################################################################
# Step 20 — Nextcloud 初始化目录结构（Company/Personal/Mobile-Backup）
##########################################################################
step 20 "初始化 Nextcloud 目录结构" || true

NC_HTML="/gspro/nextcloud/html"
NC_DATA_DIR="$NC_HTML/data/admin/files"

# 等待 Nextcloud 容器可用
if ! docker ps --format '{{.Names}}' | grep -q '^nextcloud_app$'; then
  yellow "nextcloud_app 未就绪，等待 10s..."
  sleep 10
fi

mkdir -p "$NC_DATA_DIR/Company"/{Data,Finance,HR,Legal,Projects}
mkdir -p "$NC_DATA_DIR/Personal"/{Documents,Scans,Mobile-Backup}

chown -R www-data:www-data /gspro/nextcloud/html || true

ok "Nextcloud 目录结构完成：Company/Personal/Mobile-Backup"


##########################################################################
# Step 21 — Nextcloud 插件自动安装与启用
##########################################################################
step 21 "安装并启用 Nextcloud 插件" || true

# 统一用容器名 nextcloud_app 调用 occ
occ_cmd='docker exec -u www-data nextcloud_app php -d memory_limit=1024M /var/www/html/occ'

# 等待 occ 可用
until $occ_cmd status >/dev/null 2>&1; do
  yellow "等待 Nextcloud 启动 (occ)..."
  sleep 8
done

# 推荐插件：OnlyOffice、OCR、预览生成、视频播放器、通用查看器
$occ_cmd app:install richdocuments      || true
$occ_cmd app:install ocr                || true
$occ_cmd app:install previewgenerator   || true
$occ_cmd app:install files_videoplayer  || true
$occ_cmd app:install viewer             || true

$occ_cmd app:enable richdocuments ocr previewgenerator files_videoplayer viewer

# 预览服务建议（可按需改尺寸）
$occ_cmd config:app:set previewgenerator squareSizes       --value="32 256"
$occ_cmd config:app:set previewgenerator widthSizes        --value="256 384 1024"
$occ_cmd config:app:set previewgenerator heightSizes       --value="256 384 1024"
$occ_cmd config:app:set preview jpeg_quality               --value="80"

ok "Nextcloud 插件安装并启用完成"


##########################################################################
# Step 22 — 绑定 OnlyOffice DocumentServer 到 Nextcloud
##########################################################################
step 22 "绑定 OnlyOffice 到 Nextcloud（doc.$MAIN_DOMAIN）" || true

ONLY_URL="https://doc.$MAIN_DOMAIN"

$occ_cmd config:app:set richdocuments wopi_url            --value="$ONLY_URL"
$occ_cmd config:app:set richdocuments public_wopi_url     --value="$ONLY_URL"
$occ_cmd config:app:set richdocuments enable_external_apps --value="yes"
$occ_cmd config:app:set richdocuments doc_format          --value="ooxml"

ok "OnlyOffice 已绑定至：$ONLY_URL"


##########################################################################
# Step 23 — 配置 preview 计划任务（系统 cron）
##########################################################################
step 23 "注册 Nextcloud 预览生成 cron 任务" || true

# 采用系统 cron：每晚 2:30 生成预览
CRON_LINE='30 2 * * * docker exec -u www-data nextcloud_app php -d memory_limit=1024M /var/www/html/occ preview:pre-generate > /dev/null 2>&1'
( crontab -l 2>/dev/null | grep -v 'preview:pre-generate' ; echo "$CRON_LINE" ) | crontab -

ok "预览生成 cron 已加入 (02:30 每日)"
##########################################################################
# Step 24 — 等待 NPM 启动 + 获取 API Token
##########################################################################
step 24 "等待 NPM 启动并登录获取 Token" || true

NPM_API="http://127.0.0.1:81/api"
AUTH_BASIC=$(echo -n "${NPM_USER}:${NPM_PASS}" | base64)

# 检查 NPM API 连通
until curl -s -H "Authorization: Basic $AUTH_BASIC" "$NPM_API/tokens" >/dev/null 2>&1; do
    yellow "等待 NPM API 就绪..."
    sleep 8
done

TOKEN=$(curl -s -X POST "$NPM_API/tokens" \
    -H "Authorization: Basic $AUTH_BASIC" \
    -H "Content-Type: application/json" \
    -d "{\"identity\":\"${NPM_USER}\",\"secret\":\"${NPM_PASS}\"}" | jq -r '.token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    red "NPM Token 获取失败"
    exit 1
fi

AUTH_JWT="Authorization: Bearer $TOKEN"
ok "NPM API 已登录成功"


##########################################################################
# Step 25 — 创建所有反代 Host
##########################################################################
step 25 "自动创建 NPM 反代 Host" || true

declare -A SERVICE_MAP=(
    ["$MAIN_DOMAIN"]="http://172.17.0.1:9080"
    ["wp.$MAIN_DOMAIN"]="http://172.17.0.1:9080"
    ["admin.$MAIN_DOMAIN"]="http://172.17.0.1:9080/wp-admin/network/"
    ["ezglinns.com"]="http://172.17.0.1:9080"
    ["hulin.bz"]="http://172.17.0.1:9080"
    ["doc.$MAIN_DOMAIN"]="http://172.17.0.1:9980"
    ["dri.$MAIN_DOMAIN"]="http://172.17.0.1:9000"
    ["coc.$MAIN_DOMAIN"]="http://127.0.0.1:9090"
    ["npm.$MAIN_DOMAIN"]="http://127.0.0.1:81"
    ["vnc.$MAIN_DOMAIN"]="http://127.0.0.1:6080"
)

for DOMAIN in "${!SERVICE_MAP[@]}"; do
    TARGET=${SERVICE_MAP[$DOMAIN]}

    # 确认是否已创建
    EXIST=$(curl -s -H "$AUTH_JWT" "$NPM_API/nginx/proxy-hosts" \
       | jq ".[] | select(.domain_names[]==\"$DOMAIN\") | .id")

    if [ -n "$EXIST" ]; then
        yellow "反代已存在：$DOMAIN (ID=$EXIST)"
        continue
    fi

    HOST=$(echo "$TARGET" | sed 's~http://~~' | cut -d: -f1)
    PORT=$(echo "$TARGET" | sed 's~http://~~' | cut -d: -f2)

    REQ=$(cat <<EOF
{
  "domain_names": ["$DOMAIN"],
  "forward_scheme": "http",
  "forward_host": "$HOST",
  "forward_port": $PORT,
  "allow_websocket_upgrade": true,
  "http2_support": true,
  "caching_enabled": false,
  "ssl_forced": false
}
EOF
)

    curl -s -X POST "$NPM_API/nginx/proxy-hosts" \
        -H "$AUTH_JWT" -H "Content-Type: application/json" \
        -d "$REQ" >/dev/null

    ok "已创建反代：$DOMAIN → $TARGET"
done


##########################################################################
# Step 26 — 自动申请 SSL（域名循环）
##########################################################################
step 26 "自动申请 SSL 证书" || true

SSL_DOMAINS=(
  "$MAIN_DOMAIN"
  "ezglinns.com"
  "hulin.bz"
  "wp.$MAIN_DOMAIN"
  "admin.$MAIN_DOMAIN"
  "doc.$MAIN_DOMAIN"
  "dri.$MAIN_DOMAIN"
  "coc.$MAIN_DOMAIN"
  "npm.$MAIN_DOMAIN"
  "vnc.$MAIN_DOMAIN"
)

# 小函数：根据域名查 Host ID
get_host_id(){
    curl -s -H "$AUTH_JWT" "$NPM_API/nginx/proxy-hosts" \
      | jq ".[] | select(.domain_names[]==\"$1\") | .id"
}

# 小函数：申请证书
request_cert(){
cat <<EOF
{
  "domain_names": ["$1"],
  "email": "$EMAIL_ADMIN",
  "provider": "letsencrypt",
  "challenge": "http",
  "agree_tos": true
}
EOF
}


for DOMAIN in "${SSL_DOMAINS[@]}"; do
  echo "--------"
  echo "▶ 域名：$DOMAIN"

  # DNS 检查（自动比对 $SERVER_IP）
  DNS_IP=$(dig +short $DOMAIN | tail -n1)
  if [[ "$DNS_IP" != "$SERVER_IP" ]]; then
    yellow "DNS 不正确：$DNS_IP ≠ $SERVER_IP"
    continue
  fi

  HID=$(get_host_id $DOMAIN)
  if [[ -z "$HID" ]]; then
    yellow "找不到 Proxy Host，跳过"
    continue
  fi

  # 申请证书
  RES=$(curl -s -X POST "$NPM_API/certificates" \
     -H "$AUTH_JWT" -H "Content-Type: application/json" \
     -d "$(request_cert $DOMAIN)")
  CID=$(echo "$RES" | jq -r ".id")

  if [[ -z "$CID" || "$CID" == "null" ]]; then
    yellow "首次失败，等待 20s 重试..."
    sleep 20
    RES=$(curl -s -X POST "$NPM_API/certificates" \
       -H "$AUTH_JWT" -H "Content-Type: application/json" \
       -d "$(request_cert $DOMAIN)")
    CID=$(echo "$RES" | jq -r ".id")
  fi

  if [[ -z "$CID" || "$CID" == "null" ]]; then
    red "仍然失败 → 跳过"
    continue
  fi

  # 绑定证书
  curl -s -X PUT "$NPM_API/nginx/proxy-hosts/$HID" \
    -H "$AUTH_JWT" -H "Content-Type: application/json" \
    -d "{\"certificate_id\":$CID,\"ssl_forced\":true,\"http2_support\":true}" \
    >/dev/null

  ok "SSL 已完成：$DOMAIN"
done


##########################################################################
# Step 27 — 重载 NPM 服务
##########################################################################
step 27 "重载 NPM" || true

docker exec npm nginx -s reload || true
ok "NPM 反代 & SSL 已全部生效 ✔"
##########################################################################
# Step 28 — 系统健康检测
##########################################################################
step 28 "系统健康检测与状态报告" || true

echo "→ 检查 Docker 容器状态："
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
ok "Docker 服务运行正常"

echo "→ 检查 NPM 接口健康："
curl -s http://127.0.0.1:81 | grep -q "Nginx Proxy Manager" && ok "NPM Web 界面可访问" || yellow "⚠ NPM Web 检查异常"

echo "→ 检查 Nextcloud 容器："
docker exec nextcloud_app php -v >/dev/null 2>&1 && ok "Nextcloud 容器正常" || yellow "⚠ Nextcloud 检查异常"

echo "→ 检查 WordPress 容器："
docker exec wp_fpm php -v >/dev/null 2>&1 && ok "WordPress 容器正常" || yellow "⚠ WordPress 检查异常"

echo "→ 检查 Cockpit 服务："
systemctl is-active --quiet cockpit && ok "Cockpit 服务正常" || yellow "⚠ Cockpit 检查异常"

echo "→ 检查 Fail2ban 状态："
systemctl is-active --quiet fail2ban && ok "Fail2ban 正常运行" || yellow "⚠ Fail2ban 检查异常"

echo "→ 检查防火墙："
ufw status | grep -q "active" && ok "UFW 已启用" || yellow "⚠ 防火墙未启用"


##########################################################################
# Step 29 — 最终访问信息展示
##########################################################################
step 29 "生成访问信息清单" || true

cat <<EOF

=============================================================
🎉 GS-PRO 一键部署完成！
=============================================================

✅ 主站（WordPress 多站点）：
   🌐 https://$MAIN_DOMAIN
   🔧 后台：https://wp.$MAIN_DOMAIN/wp-admin/network/

✅ Nextcloud（个人/公司云盘）：
   🌐 https://dri.$MAIN_DOMAIN

✅ OnlyOffice（在线文档编辑）：
   🌐 https://doc.$MAIN_DOMAIN

✅ Nginx Proxy Manager（反代管理）：
   🌐 https://npm.$MAIN_DOMAIN
   👤 用户名：$NPM_USER
   🔑 密码：$NPM_PASS

✅ Cockpit（服务器仪表盘）：
   🌐 https://coc.$MAIN_DOMAIN

✅ noVNC（网页远程桌面）：
   🌐 https://vnc.$MAIN_DOMAIN
   🔑 VNC 密码：$VNC_PASS

✅ aaPanel 面板：
   🌐 http://panel.$MAIN_DOMAIN:$AAPANEL_PORT

📦 数据目录结构：
   /gspro
   ├── nextcloud/
   ├── office/
   ├── wp/
   ├── npm/
   ├── config/
   ├── logs/
   └── ssl/

🔒 安全：
   • Fail2ban 已启用
   • 防火墙 UFW 已启动
   • 所有端口 80/443/5905/6080/9090 已允许

💾 脚本路径：
   /root/gspro.sh
   状态文件：/root/.gspro-progress

=============================================================
EOF

##########################################################################
# Step 30 — 标记完成
##########################################################################
step 30 "标记部署完成" || true

echo "30" > "$PROGRESS_FILE"
green "✅ 部署已全部完成！断点文件已更新。"
echo ""
echo "✨ 现在你可以安全重启 VPS 或直接访问各站点。"
echo ""
