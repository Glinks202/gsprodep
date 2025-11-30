#!/usr/bin/env bash
###############################################
# 环境检测 + 清理旧环境 (Pre-Flight Check)
###############################################

echo "=========== GS PRO: 环境检测 + 清理旧环境 ==========="

### 1. 检查系统版本（必须 24.04）
OS=$(lsb_release -rs)
if [ "$OS" != "24.04" ]; then
    echo "[ERROR] 当前？？？？系统版本：$OS"
    echo "[ERROR] 本脚本必须运行在 Ubuntu 24.04 LTS！"
    exit 1
fi
echo "[OK] Ubuntu 24.04 LTS ✔"

### 2. 停止可能冲突的服务
echo "[INFO] 停止可能冲突的服务..."
systemctl stop apache2 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop mysql 2>/dev/null || true
systemctl stop mariadb 2>/dev/null || true
systemctl stop docker 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true

### 3. 移除旧 Docker / Containerd
echo "[INFO] 清理旧 Docker / Containerd..."
apt purge -y docker docker-engine docker.io containerd \
            docker-ce docker-ce-cli containerd.io || true
rm -rf /var/lib/docker /var/lib/containerd /etc/docker

### 4. 移除旧 Web 服务（Nginx / Apache）
echo "[INFO] 清理旧 Nginx / Apache..."
apt purge -y nginx nginx-* apache2 apache2-* || true
rm -rf /etc/nginx /var/www/html

### 5. 清理旧 PHP 环境
echo "[INFO] 清理旧 PHP..."
apt purge -y php* || true
rm -rf /etc/php

### 6. 清理旧 MariaDB / MySQL
echo "[INFO] 清理旧 MariaDB / MySQL..."
apt purge -y mariadb-* mysql-* || true
rm -rf /var/lib/mysql /etc/mysql

### 7. 清理旧 Node/NPM (避免与 NPM Proxy Manager 冲突)
echo "[INFO] 清理旧 Node.js + npm..."
apt purge -y nodejs npm || true

### 8.（可选）清理旧 Nextcloud / OnlyOffice / NPM
echo "[INFO] 清理旧 Nextcloud / OnlyOffice / NPM (如存在)..."
rm -rf /var/www/nextcloud
rm -rf /opt/npm
rm -rf /opt/onlyoffice
rm -rf /usr/share/novnc /usr/bin/websockify

### 9. 清理端口占用（强制杀死占用 80/443/9443 等服务）
echo "[INFO] 清理端口占用..."
fuser -k 80/tcp 2>/dev/null || true
fuser -k 443/tcp 2>/dev/null || true
fuser -k 9443/tcp 2>/dev/null || true
fuser -k 9002/tcp 2>/dev/null || true
fuser -k 6080/tcp 2>/dev/null || true

### 10. 清理系统包缓存
apt autoremove -y
apt autoclean -y

echo "[OK] 环境检测 + 清理旧环境 完成 ✔"
echo "======================================================="
sleep 2
set -e


##############################################################
# GS PRO — FULL AUTO DEPLOY  (Ubuntu 24.04 LTS)
##############################################################

echo "================ GS PRO DEPLOY START ================"

##############################################################
# 基本变量（你给的所有信息）
##############################################################

MAIN_DOMAIN="hulin.pro"
ADMIN_EMAIL="gs@${MAIN_DOMAIN}"
SERVER_IP="82.180.137.120"

VNC_PASS="862447"
AAPANEL_PORT="8812"

PW_ADMIN="862447"
PW_STAFF="862446"
PW_SUPPORT="862445"
PW_BILLING="862444"

DOMAIN_WP="wp.${MAIN_DOMAIN}"
DOMAIN_NC="dri.${MAIN_DOMAIN}"
DOMAIN_DOC="doc.${MAIN_DOMAIN}"
DOMAIN_COC="coc.${MAIN_DOMAIN}"
DOMAIN_NPM="npm.${MAIN_DOMAIN}"
DOMAIN_PANEL="panel.${MAIN_DOMAIN}"
DOMAIN_VNC="vnc.${MAIN_DOMAIN}"

##############################################################
# ROOT CHECK
##############################################################
if [ "$(id -u)" -ne 0 ]; then
    echo "必须使用 root 用户运行！"
    exit 1
fi

##############################################################
# 更新系统 + 必备工具
##############################################################
apt update -y
apt upgrade -y
apt install -y curl wget sudo unzip zip nano git ufw jq \
lsb-release apt-transport-https software-properties-common

echo "[INFO] 系统基础环境已准备"

##############################################################
# 创建目录结构
##############################################################
BASE="/data"
PERSONAL="${BASE}/personal"
COMPANY="${BASE}/company"

mkdir -p ${PERSONAL}/{mobile,documents,passwords,archive}
mkdir -p ${COMPANY}/{ezglinns,gsliberty,finance,legal,data}
mkdir -p /backup/{nextcloud,docker}

echo "[INFO] 目录结构创建完成"

##############################################################
# 创建 SFTP 用户
##############################################################
create_user() {
    useradd -m -s /bin/bash "$1" || true
    echo "$1:$2" | chpasswd
    mkdir -p /home/$1/files
    chown -R $1:$1 /home/$1
}

create_user admin   "$PW_ADMIN"
create_user staff   "$PW_STAFF"
create_user support "$PW_SUPPORT"
create_user billing "$PW_BILLING"

echo "[INFO] SFTP 用户创建完成"


##############################################################
# Fail2ban + 白名单
##############################################################
apt install -y fail2ban

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 30m
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8  ::1 \
172.56.160.206 \
172.56.164.101 \
176.56.161.108

[sshd]
enabled = true
EOF

systemctl restart fail2ban
echo "[INFO] Fail2ban 配置完成"


##############################################################
# Docker + Portainer + NPM
##############################################################
echo "[INFO] 安装 Docker..."

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /usr/share/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
> /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker --now

echo "[INFO] Docker 安装完成"

### Portainer
docker volume create portainer_data >/dev/null 2>&1
docker run -d \
  -p 9443:9443 -p 8000:8000 \
  --name portainer \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest

### NPM
mkdir -p /opt/npm
cat >/opt/npm/docker-compose.yml <<EOF
version: "3"
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: npm
    restart: always
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - /opt/npm/data:/data
      - /opt/npm/letsencrypt:/etc/letsencrypt
EOF

docker compose -f /opt/npm/docker-compose.yml up -d

echo "[INFO] Portainer + NPM 完成"


##############################################################
# NEXTCLOUD + ONLYOFFICE + PHP + REDIS + SSL
##############################################################

apt install -y nginx mariadb-server redis-server \
php-fpm php-mysql php-zip php-gd php-mbstring php-curl php-xml \
php-intl php-bcmath php-gmp php-apcu php-imagick php-redis php-cli

systemctl enable nginx --now
systemctl enable redis-server --now
systemctl enable mariadb --now

### MySQL
mysql -e "CREATE DATABASE nextcloud;"
mysql -e "CREATE USER 'nc_user'@'localhost' IDENTIFIED BY 'NcPass123!';"
mysql -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nc_user'@'localhost'; FLUSH PRIVILEGES;"

### 下载 NC
cd /tmp
wget https://download.nextcloud.com/server/releases/latest.zip -O nc.zip
unzip nc.zip
rsync -a nextcloud/ /var/www/nextcloud/
chown -R www-data:www-data /var/www/nextcloud

### PHP 优化
PHP_INI="/etc/php/8.3/fpm/php.ini"
sed -i "s/memory_limit = .*/memory_limit = 1G/" $PHP_INI
sed -i "s/upload_max_filesize = .*/upload_max_filesize = 8G/" $PHP_INI
sed -i "s/post_max_size = .*/post_max_size = 8G/" $PHP_INI
systemctl restart php8.3-fpm

### Nginx Nextcloud
cat >/etc/nginx/sites-available/nextcloud.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_NC};
    root /var/www/nextcloud;
    index index.php;
    client_max_body_size 8G;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
}
EOF

ln -sf /etc/nginx/sites-available/nextcloud.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

### OnlyOffice
docker run -d --restart=always \
  --name onlyoffice -p 9002:80 onlyoffice/documentserver

### Nextcloud 安装
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database "mysql" \
  --database-name "nextcloud" \
  --database-user "nc_user" \
  --database-pass "NcPass123!" \
  --admin-user "admin" \
  --admin-pass "Gaomeilan862447#" \
  --data-dir "/data/company/data"

### Redis 加速
sed -i "/memcache.local/d" /var/www/nextcloud/config/config.php
cat >>/var/www/nextcloud/config/config.php <<EOF
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' => [
    'host' => '127.0.0.1',
    'port' => 6379,
  ],
EOF

### SSL
apt install -y certbot python3-certbot-nginx
certbot --nginx -d "${DOMAIN_NC}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive


##############################################################
# Cockpit + Proxy + SSL
##############################################################

apt install -y cockpit cockpit-pcp cockpit-networkmanager
systemctl enable cockpit --now

cat >/etc/nginx/sites-available/cockpit.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_COC};
    location / {
        proxy_pass https://127.0.0.1:9090;
        proxy_ssl_verify off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/cockpit.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d "${DOMAIN_COC}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive


##############################################################
# admin.hulin.pro — 管理中心
##############################################################

mkdir -p /var/www/admin-center
cat >/var/www/admin-center/index.html <<EOF
<!doctype html><html><head><title>GS PRO Admin</title>
<style>body{text-align:center;font-family:Arial;background:#111;color:#eee;padding:30px}
a{display:block;margin:15px auto;padding:12px;width:320px;background:#222;color:#0af;
text-decoration:none;border-radius:8px;font-size:20px}</style></head><body>
<h1>GS PRO Admin Center</h1>
<a href="https://${DOMAIN_COC}">Cockpit</a>
<a href="https://${DOMAIN_PANEL}:${AAPANEL_PORT}">aaPanel</a>
<a href="https://${DOMAIN_NC}">Nextcloud</a>
<a href="https://${DOMAIN_WP}">WordPress</a>
<a href="http://${SERVER_IP}:81">NPM</a>
</body></html>
EOF

cat >/etc/nginx/sites-available/admin.conf <<EOF
server {
    listen 80;
    server_name admin.${MAIN_DOMAIN};
    root /var/www/admin-center;
}
EOF

ln -sf /etc/nginx/sites-available/admin.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d "admin.${MAIN_DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive


##############################################################
# aaPanel 反代
##############################################################

cat >/etc/nginx/sites-available/aapanel.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_PANEL};
    location / {
        proxy_pass http://127.0.0.1:${AAPANEL_PORT};
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/aapanel.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d "${DOMAIN_PANEL}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive


##############################################################
# WordPress + Proxy + SSL
##############################################################

mkdir -p /var/www/wordpress
if [ ! -f /var/www/wordpress/index.php ]; then
  wget -O /tmp/wp.tgz https://wordpress.org/latest.tar.gz
  tar -xzf /tmp/wp.tgz -C /var/www/
  mv /var/www/wordpress/* /var/www/wordpress/
  chown -R www-data:www-data /var/www/wordpress
fi

cat >/etc/nginx/sites-available/wordpress.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_WP};
    root /var/www/wordpress;
    index index.php;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
}
EOF

ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

certbot --nginx -d "${DOMAIN_WP}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive


##############################################################
# VNC via noVNC 反代
##############################################################

apt install -y websockify novnc

nohup websockify --web=/usr/share/novnc/ 6080 127.0.0.1:5905 >/dev/null 2>&1 &

cat >/etc/nginx/sites-available/vnc.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_VNC};
    location / {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

ln -sf /etc/nginx/sites-available/vnc.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d "${DOMAIN_VNC}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive


##############################################################
# 自动备份
##############################################################

cat >/usr/local/bin/gs_backup.sh <<'EOF'
#!/usr/bin/env bash
DATE=$(date +"%Y-%m-%d")
tar -czf /backup/nextcloud/nc-$DATE.tar.gz /var/www/nextcloud
tar -czf /backup/docker/npm-$DATE.tar.gz /opt/npm
tar -czf /backup/docker/portainer-$DATE.tar.gz /var/lib/docker/volumes
EOF

chmod +x /usr/local/bin/gs_backup.sh
echo "0 3 * * * root /usr/local/bin/gs_backup.sh" >/etc/cron.d/gs_backup


##############################################################
# 自动健康检测
##############################################################

cat >/usr/local/bin/health_check.sh <<EOF
#!/usr/bin/env bash
SERVICES=(nginx php8.3-fpm redis-server mysql docker)
for S in "\${SERVICES[@]}"; do
  systemctl is-active --quiet \$S || systemctl restart \$S
done
EOF

chmod +x /usr/local/bin/health_check.sh
echo "*/5 * * * * root /usr/local/bin/health_check.sh" >/etc/cron.d/health_check


##############################################################
# 完成
##############################################################

echo "
======================================================
GS PRO 自动化一键部署成功！

管理入口：https://admin.${MAIN_DOMAIN}

Nextcloud：     https://${DOMAIN_NC}
OnlyOffice：    http://${SERVER_IP}:9002
WordPress：     https://${DOMAIN_WP}
Cockpit：       https://${DOMAIN_COC}
aaPanel：       https://${DOMAIN_PANEL}
NPM：           http://${SERVER_IP}:81
VNC：           https://${DOMAIN_VNC}

SFTP:
admin   ${PW_ADMIN}
staff   ${PW_STAFF}
support ${PW_SUPPORT}
billing ${PW_BILLING}

所有 SSL、反向代理、文件结构、监控、备份 已自动完成
======================================================
"
