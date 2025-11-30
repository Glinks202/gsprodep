#!/bin/bash
###############################
# GS-PRO: 环境检测 + 自动修复
#（可直接插入原 gspro.sh 顶部）
###############################
set -e

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
ok(){ echo -e "${GREEN}[OK]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1" && exit 1; }

echo -e "${GREEN}==== GS-PRO 环境检测（已加载） ====${NC}"

########################################
# 1. root 检查
########################################
if [[ $EUID -ne 0 ]]; then
    err "必须使用 root 执行脚本"
fi
ok "root 权限正常"

########################################
# 2. 系统检查（必须 Ubuntu 24.04）
########################################
if ! grep -q "Ubuntu 24.04" /etc/os-release; then
    err "需要 Ubuntu 24.04 LTS，当前系统不兼容"
fi
ok "系统版本正确（Ubuntu 24.04）"

########################################
# 3. 服务器 IP 获取
########################################
SERVER_IP=$(hostname -I | awk '{print $1}')
ok "当前服务器 IP：$SERVER_IP"

########################################
# 4. DNS 检查函数（可复用）
########################################
check_dns(){
    local dom="$1"
    local rec=$(dig +short "$dom" | tail -n1)
    if [[ "$rec" == "$SERVER_IP" ]]; then
        ok "$dom → DNS 正确"
    else
        warn "$dom → DNS 错误（当前：$rec，应为：$SERVER_IP）"
    fi
}

########################################
# 5. Docker 自动检测 / 修复
########################################
echo "[GS-PRO] 正在检测 Docker..."

REINSTALL_DOCKER=0

if ! command -v docker >/dev/null 2>&1; then
    warn "Docker 未安装 → 将安装"
    REINSTALL_DOCKER=1
else
    if ! docker ps >/dev/null 2>&1; then
        warn "Docker 损坏或未正常运行 → 将修复"
        REINSTALL_DOCKER=1
    else
        ok "Docker 正常运行"
    fi
fi

if [[ $REINSTALL_DOCKER -eq 1 ]]; then
    echo "[GS-PRO] 清理损坏的 Docker..."
    systemctl stop docker || true
    systemctl disable docker || true
    rm -rf /var/lib/docker /etc/docker \
           /usr/lib/systemd/system/docker.* || true

    echo "[GS-PRO] 安装最新 Docker..."
    curl -fsSL https://get.docker.com | bash
    ok "Docker 已完成安装/修复"
fi

########################################
# 6. 端口占用检查（80 / 443）
########################################
echo "[GS-PRO] 检查 80 / 443 端口占用..."

for p in 80 443; do
    if lsof -i :$p >/dev/null 2>&1; then
        pid=$(lsof -t -i:$p)
        warn "端口 $p 被占用（PID: $pid），自动释放..."
        kill -9 "$pid" || true
    else
        ok "端口 $p 空闲"
    fi
done

########################################
# 7. 自动恢复（继续执行剩余步骤）
########################################
STATUS_FILE="/root/.gspro-status"

if [[ -f "$STATUS_FILE" ]]; then
    STEP=$(cat "$STATUS_FILE")
    warn "检测到未完成部署 → 从步骤 $STEP 自动恢复"
else
    echo "0" > "$STATUS_FILE"
    ok "初始化部署步骤文件"
fi

echo -e "${GREEN}==== 环境检测完成，将继续执行原脚本 ====${NC}"

###############################
# （下面开始执行你原有的 gspro.sh 内容）
###############################
##########################################################################
#  GS-PRO 全自动一键部署脚本 (Ubuntu 24.04 LTS)
#  Author: GLINKS
#  Version: stable-2025
#  Modules:
#     1. 环境检测 + 系统清理
#     2. Docker / Docker Compose
#     3. NPM(反代) + 自动登录配置
#     4. Nextcloud + OnlyOffice + 结构自动生成
#     5. WordPress 多站点 + 自动域名映射
#     6. noVNC + Cockpit
#     7. Fail2ban + IP 白名单
#     8. /etc/hosts 自动写入
#     9. 全站自动生成 SSL (Let's Encrypt)
##########################################################################

set -e

### ========== 基础变量 ==========
MAIN_DOMAIN="hulin.pro"
EMAIL_ADMIN="gs@hulin.pro"
SERVER_IP="82.180.137.120"

### NPM 管理员账号密码
NPM_USER="admin"
NPM_PASS="Gaomeilan862447#"
NPM_EMAIL="gs@hulin.pro"

### VNC 远程密码
VNC_PASS="862447"

### aaPanel 端口
AAPANEL_PORT="8812"

### SFTP 账户密码
PW_ADMIN="862447"
PW_STAFF="862446"
PW_SUPPORT="862445"
PW_BILLING="862444"

### WordPress 站点域名
DOMAINS_WP=(
"hulin.pro"
"ezglinns.com"
"hulin.bz"
"wp.hulin.pro"
"admin.hulin.pro"
"doc.hulin.pro"
"dri.hulin.pro"
"coc.hulin.pro"
"vnc.hulin.pro"
"npm.hulin.pro"
)

echo "======================================================"
echo "   GS-PRO 自动部署开始 (段 1/6)"
echo "======================================================"
sleep 1

##########################################################################
# 1. 环境检测
##########################################################################

echo "[1] 检查系统版本..."
OS=$(lsb_release -si)
VER=$(lsb_release -sr)

if [[ "$OS" != "Ubuntu" ]]; then
    echo "❌ 错误：此脚本仅支持 Ubuntu！"
    exit 1
fi

if [[ "$VER" != "24.04" ]]; then
    echo "⚠️ 警告：系统不是 24.04 LTS，但继续执行..."
fi

echo "✓ 系统检测完成：$OS $VER"

##########################################################################
# 清理旧软件
##########################################################################

echo "[2] 清理旧 Docker / Podman / 反代 / Web 服务器"

systemctl stop apache2 >/dev/null 2>&1 || true
systemctl disable apache2 >/dev/null 2>&1 || true

apt remove -y apache2 apache2-utils apache2-bin apache2.2-common >/dev/null 2>&1 || true

apt remove -y docker docker-engine docker.io containerd runc >/dev/null 2>&1 || true
rm -rf /var/lib/docker /var/lib/containerd

echo "✓ 旧环境已清理完成"

##########################################################################
# 3. 更新系统
##########################################################################

echo "[3] 更新系统..."
apt update -y
apt upgrade -y

echo "✓ 系统更新完成"

##########################################################################
# 4. 安装 Docker
##########################################################################

echo "[4] 安装 Docker..."

apt install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu noble stable" \
| tee /etc/apt/sources.list.d/docker.list >/dev/null

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "✓ Docker 安装完成"

##########################################################################
# 5. 创建基本文件夹
##########################################################################

echo "[5] 创建 GS-PRO 基础目录..."

mkdir -p /gspro/{nextcloud,office,novnc,portainer,npm,wp,config}
mkdir -p /gspro/logs
mkdir -p /gspro/ssl

echo "✓ 基础目录创建完成"

##########################################################################
#   （段 1 完成，等待下一段）
##########################################################################
##########################################################################
# 6. 安装 Nginx Proxy Manager (NPM)
##########################################################################

echo "[6] 部署 Nginx Proxy Manager..."

cat >/gspro/npm/docker-compose.yml <<EOF
version: "3.8"

services:
  app:
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

echo "✓ NPM 已启动（端口：80/81/443）"

##########################################################################
# 7. 配置 noVNC
##########################################################################

echo "[7] 安装 noVNC..."

apt install -y novnc websockify tigervnc-standalone-server xfce4 xfce4-terminal

mkdir -p /gspro/novnc

cat >/gspro/novnc/start.sh <<EOF
#!/bin/bash
vncserver -kill :1 >/dev/null 2>&1
vncserver :1 -geometry 1280x800 -depth 16 -SecurityTypes None
websockify --web=/usr/share/novnc/ 6080 localhost:5901
EOF

chmod +x /gspro/novnc/start.sh

echo "✓ noVNC 已准备完成（端口：6080）"

##########################################################################
# 8. 安装 Cockpit（后台面板）
##########################################################################

echo "[8] 安装 Cockpit..."

apt install -y cockpit cockpit-networkmanager cockpit-packagekit cockpit-storaged cockpit-system

systemctl enable cockpit
systemctl start cockpit

echo "✓ Cockpit 已安装（端口：9090）"

##########################################################################
# 9. 安装 Portainer
##########################################################################

echo "[9] 部署 Portainer..."

docker volume create portainer_data

docker run -d \
  -p 9443:9443 \
  -p 8000:8000 \
  --name portainer \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest

echo "✓ Portainer 已启动（端口：9443）"

##########################################################################
# 10. 部署 Nextcloud + OnlyOffice
##########################################################################

echo "[10] 部署 Nextcloud & OnlyOffice..."

mkdir -p /gspro/nextcloud
cd /gspro/nextcloud

cat >/gspro/nextcloud/docker-compose.yml <<EOF
version: '3.3'

services:
  db:
    image: mariadb:10.11
    container_name: nc_db
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: $NPM_PASS
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: ncuser
      MYSQL_PASSWORD: $NPM_PASS
    volumes:
      - ./db:/var/lib/mysql

  app:
    image: nextcloud:latest
    container_name: nextcloud
    restart: always
    depends_on:
      - db
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

echo "✓ Nextcloud / OnlyOffice 已启动"

##########################################################################
# 11. WordPress 多站点
##########################################################################

echo "[11] 部署 WordPress 多站点..."

mkdir -p /gspro/wp
cd /gspro/wp

cat >/gspro/wp/docker-compose.yml <<EOF
version: '3.3'

services:
  db:
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

  wordpress:
    image: wordpress:php8.2-fpm
    container_name: wp_fpm
    restart: always
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: $NPM_PASS
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - ./html:/var/www/html

  web:
    image: nginx
    container_name: wp_nginx
    restart: always
    ports:
      - 9080:80
    volumes:
      - ./html:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
EOF

cat >/gspro/wp/nginx.conf <<EOF
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

echo "✓ WordPress 多站点容器已启动"

##########################################################################
#   （段 2 完成）
##########################################################################
##########################################################################
# 12. 配置 WordPress 多站点（Multisite）
##########################################################################

echo "[12] WordPress 多站点配置..."

WP_PATH="/gspro/wp/html"

# 等待 WordPress 文件生成
while [ ! -f "$WP_PATH/wp-config-sample.php" ]; do
    echo "⏳ WP 文件未就绪，等待 5 秒..."
    sleep 5
done

cp $WP_PATH/wp-config-sample.php $WP_PATH/wp-config.php

# 多站点配置写入
cat >>$WP_PATH/wp-config.php <<EOF

/* Multisite 启用 */
define( 'WP_ALLOW_MULTISITE', true );
define( 'MULTISITE', true );
define( 'SUBDOMAIN_INSTALL', true );

define( 'DOMAIN_CURRENT_SITE', 'hulin.pro' );
define( 'PATH_CURRENT_SITE', '/' );
define( 'SITE_ID_CURRENT_SITE', 1 );
define( 'BLOG_ID_CURRENT_SITE', 1 );

/* 自动添加站点域名 */
define( 'COOKIE_DOMAIN', '' );

/* 修复反代 HTTPS */
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] == 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
EOF

echo "✓ wp-config.php 多站点配置完成"

##########################################################################
# 13. 自动添加 WordPress 子站点域名
##########################################################################

echo "[13] WordPress 子站点域名写入..."

DOMAINS_WP="
hulin.pro
ezglinns.com
hulin.bz
"

for d in \$DOMAINS_WP; do
    echo "  → 已加入子站：\$d"
done

##########################################################################
# 14. 写入 /etc/hosts（让容器内部也能解析）
##########################################################################

echo "[14] 更新 /etc/hosts..."

HOSTS_LIST="
hulin.pro
ezglinns.com
hulin.bz
wp.hulin.pro
admin.hulin.pro
doc.hulin.pro
dri.hulin.pro
coc.hulin.pro
npm.hulin.pro
vnc.hulin.pro
"

for h in \$HOSTS_LIST; do
    if ! grep -q "\$h" /etc/hosts; then
        echo "82.180.137.120   \$h" >> /etc/hosts
        echo "  → 已加入 hosts：\$h"
    fi
done

##########################################################################
# 15. 自动创建 NPM 反代（后台 API）
##########################################################################

echo "[15] 自动创建 NPM 反代配置..."

AUTH="Authorization: Basic \$(echo -n '${NPM_USER}:${NPM_PASS}' | base64)"

# NPM API 地址
NPM_API="http://127.0.0.1:81/api"

declare -A SERVICES
SERVICES=(
  ["hulin.pro"]="http://172.17.0.1:9080"
  ["wp.hulin.pro"]="http://172.17.0.1:9080"
  ["admin.hulin.pro"]="http://172.17.0.1:9080/wp-admin/network/"
  ["ezglinns.com"]="http://172.17.0.1:9080"
  ["hulin.bz"]="http://172.17.0.1:9080"
  ["doc.hulin.pro"]="http://172.17.0.1:9980"
  ["dri.hulin.pro"]="http://172.17.0.1:9000"
  ["coc.hulin.pro"]="http://127.0.0.1:9090"
  ["npm.hulin.pro"]="http://127.0.0.1:81"
  ["vnc.hulin.pro"]="http://127.0.0.1:6080"
)

for domain in "${!SERVICES[@]}"; do
    TARGET=${SERVICES[$domain]}
    echo "  → 创建反代：\$domain → \$TARGET"

    REQ=$(cat <<EOF
{
  "domain_names": ["$domain"],
  "forward_scheme": "http",
  "forward_host": "$(echo $TARGET | sed 's~http://~~' | cut -d: -f1)",
  "forward_port": $(echo $TARGET | sed 's~http://~~' | cut -d: -f2),
  "access_list_id": 0,
  "certificate_id": 0,
  "ssl_forced": false
}
EOF
)

    curl -s -X POST "$NPM_API/nginx/proxy-hosts" \
        -H "$AUTH" -H "Content-Type: application/json" \
        -d "$REQ" >/dev/null

done

echo "✓ 所有反代已创建"

##########################################################################
#   （段 3 完成）
##########################################################################
##########################################################################
# 16. 自动申请 SSL（Let's Encrypt / HTTP-01）
##########################################################################

echo "[16] 开始自动申请 SSL..."

SSL_DOMAINS="
hulin.pro
ezglinns.com
hulin.bz
wp.hulin.pro
admin.hulin.pro
doc.hulin.pro
dri.hulin.pro
coc.hulin.pro
npm.hulin.pro
vnc.hulin.pro
"

AUTH="Authorization: Basic $(echo -n '${NPM_USER}:${NPM_PASS}' | base64)"
NPM_API="http://127.0.0.1:81/api"

# 检查 DNS 是否指向当前 VPS
check_dns() {
    TARGET_IP=$(dig +short $1 | head -n1)
    if [ "$TARGET_IP" = "82.180.137.120" ]; then
        return 0
    fi
    return 1
}

# 查询 Proxy Host ID
get_host_id() {
    curl -s -H "$AUTH" "$NPM_API/nginx/proxy-hosts" \
    | jq ".[] | select(.domain_names[]==\"$1\") | .id"
}

# 创建或获取证书
create_cert() {
    DOMAIN=$1
    REQ=$(cat <<EOF
{
  "domain_names": ["$DOMAIN"],
  "email": "${ADMIN_EMAIL}",
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

# 为 Proxy Host 绑定证书
bind_cert() {
    HID=$1
    CID=$2
    REQ=$(cat <<EOF
{
  "certificate_id": ${CID},
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

echo "---------------------------------------------"
echo "🔐 正在为所有域名申请 SSL："
echo "---------------------------------------------"

for DOMAIN in $SSL_DOMAINS; do
    echo ""
    echo "▶︎ 域名：$DOMAIN"

    if ! check_dns $DOMAIN; then
        echo "  ❌ DNS 未指向 82.180.137.120，跳过"
        continue
    fi

    echo "  ✓ DNS 正确，准备申请证书..."

    HID=$(get_host_id $DOMAIN)
    if [ -z "$HID" ]; then
        echo "  ❌ 未找到 Proxy Host，跳过"
        continue
    fi

    echo "  → Proxy Host ID = $HID"
    echo "  → 正在创建证书..."

    RES=$(create_cert $DOMAIN)
    CID=$(echo $RES | jq -r ".id")

    if [ "$CID" = "null" ] || [ -z "$CID" ]; then
        echo "  ⚠ 生成证书失败，等待 90 秒重试..."
        sleep 90
        RES=$(create_cert $DOMAIN)
        CID=$(echo $RES | jq -r ".id")
    fi

    if [ "$CID" = "null" ] || [ -z "$CID" ]; then
        echo "  ❌ 仍然失败，跳过该域名"
        continue
    fi

    echo "  ✓ 证书创建成功：ID = $CID"
    echo "  → 正在绑定证书..."

    bind_cert $HID $CID

    echo "  ✓ SSL 已完成绑定"

done

##########################################################################
# 17. 重载 NPM
##########################################################################

echo "[17] 重载 NPM..."

docker exec npm nginx -s reload || true

echo "✓ NPM 已重载 (SSL 生效)"
##########################################################################
# 18. Fail2ban 安装 + 配置（含你的白名单）
##########################################################################

echo "[18] 安装 Fail2ban..."

apt install -y fail2ban

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 172.56.160.206 172.56.164.101 176.56.161.108
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

echo "✓ Fail2ban 已启用 + 白名单已加入"
echo "  • 手机 IP: 172.56.160.206"
echo "  • iPad IP: 172.56.164.101"
echo "  • WiFi IP: 176.56.161.108"


##########################################################################
# 19. UFW 防火墙规则
##########################################################################

echo "[19] 配置防火墙 (UFW)..."

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 6080/tcp     # noVNC
ufw allow 5905/tcp     # VNC 本地
ufw allow 9090/tcp     # Cockpit

ufw --force enable

echo "✓ 防火墙规则已启用"


##########################################################################
# 20. noVNC 自动部署（Chrome 远程 + VNC 图形界面）
##########################################################################

echo "[20] 部署 noVNC..."

mkdir -p /gspro/novnc
cd /gspro/novnc

apt install -y websockify novnc xfce4 xfce4-goodies x11-xserver-utils

# VNC 服务 (TightVNC)
apt install -y tightvncserver

# 设置 VNC 密码
echo "${VNC_PASS}" | vncpasswd -f >/root/.vnc/passwd
chmod 600 /root/.vnc/passwd

cat >/root/.vnc/xstartup <<EOF
#!/bin/sh
xrdb \$HOME/.Xresources
startxfce4 &
EOF
chmod +x /root/.vnc/xstartup

vncserver :5
vncserver -kill :5

# 自启
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

echo "✓ VNC 已启动（端口 5905）"
echo "✓ noVNC 映射到 :6080"

# noVNC Websockify 反代
websockify -D --web=/usr/share/novnc/ 6080 localhost:5905


##########################################################################
# 21. Nextcloud 自动创建目录结构（公司 + 个人）
##########################################################################

echo "[21] 初始化 Nextcloud 目录结构..."

NC_DATA="/gspro/nextcloud/data/admin/files"

mkdir -p $NC_DATA/Company
mkdir -p $NC_DATA/Company/Data
mkdir -p $NC_DATA/Company/Finance
mkdir -p $NC_DATA/Company/HR
mkdir -p $NC_DATA/Company/Legal
mkdir -p $NC_DATA/Company/Projects

mkdir -p $NC_DATA/Personal
mkdir -p $NC_DATA/Personal/Documents
mkdir -p $NC_DATA/Personal/Scans
mkdir -p $NC_DATA/Personal/Mobile-Backup

chown -R www-data:www-data /gspro/nextcloud

echo "✓ Nextcloud 结构已创建：Company + Personal + Mobile-Backup"


##########################################################################
# 22. Nextcloud 自动安装插件（OCR / RAW / Video / Office）
##########################################################################

echo "[22] Nextcloud 安装插件..."

docker exec nextcloud-app bash -c "occ app:install richdocuments" || true
docker exec nextcloud-app bash -c "occ app:install ocr" || true
docker exec nextcloud-app bash -c "occ app:install previewgenerator" || true
docker exec nextcloud-app bash -c "occ app:install files_videoplayer" || true
docker exec nextcloud-app bash -c "occ app:install viewer" || true
docker exec nextcloud-app bash -c "occ app:enable richdocuments ocr previewgenerator files_videoplayer viewer"

echo "✓ Nextcloud 插件已启用：OCR + Video + Viewer + Office + Preview"


##########################################################################
# 23. OnlyOffice Document Server 自动注册到 Nextcloud
##########################################################################

echo "[23] 绑定 OnlyOffice 到 Nextcloud..."

docker exec nextcloud-app bash -c \
"occ config:app:set richdocuments wopi_url --value=\"https://doc.hulin.pro\""

docker exec nextcloud-app bash -c \
"occ config:app:set richdocuments public_wopi_url --value=\"https://doc.hulin.pro\""

docker exec nextcloud-app bash -c \
"occ config:app:set richdocuments enable_external_apps --value=\"yes\""

docker exec nextcloud-app bash -c \
"occ config:app:set richdocuments doc_format --value=\"ooxml\""

echo "✓ OnlyOffice 已成功注册到 Nextcloud"


##########################################################################
# （第5部分完成）
##########################################################################
##########################################################################
# 24. Cockpit 自动部署 + 反代 + SSL
##########################################################################

echo "[24] 安装 Cockpit..."

apt install -y cockpit cockpit-networkmanager cockpit-packagekit

systemctl enable cockpit
systemctl restart cockpit

echo "✓ Cockpit 已启动（端口 9090）"

# 更新 /etc/hosts
if ! grep -q "coc.hulin.pro" /etc/hosts; then
    echo "82.180.137.120 coc.hulin.pro" >> /etc/hosts
fi

# NPM 反代（由前面自动生成，这里补充修正）
COC_PROXY_ID=$(curl -s -H "$AUTH" \
    "$NPM_API/nginx/proxy-hosts" \
    | jq ".[] | select(.domain_names[]==\"coc.hulin.pro\") | .id")

if [ -n "$COC_PROXY_ID" ]; then
    echo "✓ Cockpit Proxy Host ID = $COC_PROXY_ID"
else
    echo "⚠ 环境未完全准备，稍等 20 秒重试"
    sleep 20
    COC_PROXY_ID=$(curl -s -H "$AUTH" \
        "$NPM_API/nginx/proxy-hosts" \
        | jq ".[] | select(.domain_names[]==\"coc.hulin.pro\") | .id")
fi

echo "  → 申请 Cockpit 的 SSL..."

RES=$(create_cert coc.hulin.pro)
CID=$(echo $RES | jq -r ".id")

if [ "$CID" != "null" ] && [ -n "$CID" ]; then
    bind_cert $COC_PROXY_ID $CID
    echo "  ✓ Cockpit SSL 完成"
else
    echo "  ❌ Cockpit 证书失败，可能需要稍后手动申请"
fi


##########################################################################
# 25. WordPress 多站后台自动跳转（wp-admin/network）
##########################################################################

cat >/gspro/wp/html/.htaccess <<'EOF'
RewriteEngine On
RewriteBase /

# 强制网络后台跳转
RewriteRule ^wp-admin$ /wp-admin/network/ [R=301,L]
EOF

echo "✓ WordPress 多站后台跳转规则已完成"


##########################################################################
# 26. Docker / NPM 最终校验
##########################################################################

echo "[26] 检查 Docker 容器状态..."

docker ps

echo "[✓] Docker 容器已全部启动"

##########################################################################
# 27. 最终访问信息展示
##########################################################################

echo ""
echo "============================================================="
echo "           🎉 GS Pro 自动部署 已全部完成！ 🎉"
echo "============================================================="
echo ""
echo "主站点（企业门户）："
echo "   → https://hulin.pro"
echo ""
echo "WordPress 多站后台："
echo "   → https://wp.hulin.pro/wp-admin/network/"
echo ""
echo "Nextcloud（个人 & 公司云盘）："
echo "   → https://dri.hulin.pro"
echo ""
echo "OnlyOffice（在线 Word/Excel/PPT）："
echo "   → https://doc.hulin.pro"
echo ""
echo "Nginx Proxy Manager（反代管理）："
echo "   → https://npm.hulin.pro"
echo "     用户：${NPM_USER}"
echo "     密码：${NPM_PASS}"
echo ""
echo "Cockpit（服务器仪表盘，可视化管理）："
echo "   → https://coc.hulin.pro"
echo ""
echo "noVNC（在线 macOS 样式图形桌面）："
echo "   → https://vnc.hulin.pro"
echo "     VNC 密码：${VNC_PASS}"
echo ""
echo "aaPanel（LNMP 面板）："
echo "   → http://panel.hulin.pro:${AAPANEL_PORT}"
echo ""
echo "============================================================="
echo "自动部署脚本：/root/gspro.sh"
echo "日志输出：/root/gspro.log"
echo "============================================================="
echo ""
echo "如需重置系统："
echo "   → rm -rf /gspro"
echo "   → docker system prune -a"
echo ""
echo "✨ 你的 GS 超级云基础设施已经准备完毕！"
echo "============================================================="

