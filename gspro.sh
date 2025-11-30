#!/usr/bin/env bash
set -e

#######################################################################
# GS PRO — FULL AUTO DEPLOY SCRIPT
# Ubuntu 24.04 LTS  |  By ChatGPT + Hulin Gao  |  2025-11-30
#######################################################################

echo "================ GS PRO 自动化部署开始 ================"

#######################################################################
#   0. 环境检测 + 清理旧环境
#######################################################################

echo "[检测] 检查是否为 root 用户..."
if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 必须使用 root 运行脚本！"
    exit 1
fi
echo "[OK] root 用户 ✔"

echo "[检测] 检查系统版本是否为 Ubuntu 24.04..."
OS=$(lsb_release -rs)
if [ "$OS" != "24.04" ]; then
    echo "[错误] 系统版本为 $OS，本脚本仅支持 Ubuntu 24.04 LTS"
    exit 1
fi
echo "[OK] Ubuntu 24.04 ✔"

echo "[清理] 停止可能冲突的服务..."
systemctl stop apache2 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl stop mysql 2>/dev/null || true
systemctl stop mariadb 2>/dev/null || true
systemctl stop docker 2>/dev/null || true
systemctl stop containerd 2>/dev/null || true

echo "[清理] 卸载旧 Docker..."
apt purge -y docker docker.io docker-engine containerd docker-ce docker-ce-cli containerd.io || true
rm -rf /var/lib/docker /var/lib/containerd /etc/docker

echo "[清理] 卸载旧 Nginx / Apache..."
apt purge -y nginx nginx-* apache2 apache2-* || true
rm -rf /etc/nginx /var/www/html

echo "[清理] 卸载旧 PHP..."
apt purge -y php* || true
rm -rf /etc/php

echo "[清理] 卸载旧 MariaDB / MySQL..."
apt purge -y mariadb-* mysql-* || true
rm -rf /var/lib/mysql /etc/mysql

echo "[清理] 卸载旧 Node / npm..."
apt purge -y nodejs npm || true

echo "[清理] 关闭占用端口的进程..."
fuser -k 80/tcp 2>/dev/null || true
fuser -k 443/tcp 2>/dev/null || true
fuser -k 9443/tcp 2>/dev/null || true
fuser -k 9002/tcp 2>/dev/null || true
fuser -k 6080/tcp 2>/dev/null || true

echo "[清理] 自动移除旧包..."
apt autoremove -y
apt autoclean -y

echo "======== 环境清理完成，开始正式部署 ========"
sleep 1

#######################################################################
# 1. 基础变量配置（你的专属配置）
#######################################################################

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

echo "[INFO] 主域名: ${MAIN_DOMAIN}"

#######################################################################
# 2. 更新系统 & 安装基础工具
#######################################################################

apt update -y && apt upgrade -y
apt install -y curl wget sudo unzip zip nano git ufw jq \
apt-transport-https software-properties-common lsb-release

echo "[OK] 基础工具已安装 ✔"

#######################################################################
# 3. 创建目录结构
#######################################################################

BASE="/data"
PERSONAL="${BASE}/personal"
COMPANY="${BASE}/company"

mkdir -p ${PERSONAL}/{mobile,documents,passwords,archive}
mkdir -p ${COMPANY}/{ezglinns,gsliberty,finance,legal,data}
mkdir -p /backup/{nextcloud,docker}

echo "[OK] 目录结构已创建 ✔"

#######################################################################
# 4. 创建用户
#######################################################################

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

echo "[OK] SFTP 用户已创建 ✔"

#######################################################################
# 5. Fail2ban + 白名单
#######################################################################

apt install -y fail2ban

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 30m
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 \
172.56.160.206 \
172.56.164.101 \
176.56.161.108

[sshd]
enabled = true
EOF

systemctl restart fail2ban

echo "[OK] Fail2ban 完成 ✔"

#######################################################################
# 6. 安装 Docker + Portainer + NPM
#######################################################################

echo "[部署] 安装 Docker..."

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /usr/share/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
> /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker --now

echo "[OK] Docker 完成 ✔"

### Portainer
docker volume create portainer_data >/dev/null 2>&1
docker run -d --restart=always \
  -p 9443:9443 -p 8000:8000 \
  --name portainer \
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

echo "[OK] Portainer + NPM 完成 ✔"

#######################################################################
# 7. 安装 Nextcloud + OnlyOffice + MariaDB + Redis + Nginx
#######################################################################

apt install -y nginx mariadb-server redis-server \
php-fpm php-mysql php-zip php-gd php-mbstring php-curl php-xml \
php-intl php-bcmath php-gmp php-apcu php-imagick php-redis php-cli

systemctl enable nginx --now
systemctl enable redis-server --now
systemctl enable mariadb --now

# MariaDB
mysql -e "CREATE DATABASE nextcloud;"
mysql -e "CREATE USER 'nc_user'@'localhost' IDENTIFIED BY 'NcPass123!';"
mysql -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nc_user'@'localhost'; FLUSH PRIVILEGES;"

# Nextcloud 下载
cd /tmp
wget https://download.nextcloud.com/server/releases/latest.zip -O nc.zip
unzip nc.zip
rsync -a nextcloud/ /var/www/nextcloud/
chown -R www-data:www-data /var/www/nextcloud

# PHP 优化
PHP_INI="/etc/php/8.3/fpm/php.ini"
sed -i "s/memory_limit = .*/memory_limit = 1G/" $PHP_INI
sed -i "s/upload_max_filesize = .*/upload_max_filesize = 8G/" $PHP_INI
sed -i "s/post_max_size = .*/post_max_size = 8G/" $PHP_INI

systemctl restart php8.3-fpm

# Nginx 配置 Nextcloud
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

# OnlyOffice
docker run -d --restart=always \
  --name onlyoffice -p 9002:80 \
  onlyoffice/documentserver

# Nextcloud 安装
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database "mysql" \
  --database-name "nextcloud" \
  --database-user "nc_user" \
  --database-pass "NcPass123!" \
  --admin-user "admin" \
  --admin-pass "Gaomeilan862447#" \
  --data-dir "/data/company/data"

# Redis 加速
sed -i "/memcache.local/d" /var/www/nextcloud/config/config.php
cat >>/var/www/nextcloud/config/config.php <<EOF
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' => [
    'host' => '127.0.0.1',
    'port' => 6379,
  ],
EOF

# SSL for Nextcloud
apt install -y certbot python3-certbot-nginx
certbot --nginx -d "${DOMAIN_NC}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive

#######################################################################
# 8. 安装 Cockpit + 反代 + SSL
#######################################################################

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

#######################################################################
# 9. 管理中心 admin.hulin.pro
#######################################################################

mkdir -p /var/www/admin-center
cat >/var/www/admin-center/index.html <<EOF
<!doctype html><html><head><title>GS PRO Admin</title>
<style>body{text-align:center;font-family:Arial;background:#111;color:#eee;padding:30px}
a{display:block;margin:15px auto;padding:12px;width:320px;background:#222;color:#0af;
text-decoration:none;border-radius:8px;font-size:20px}</style></head><body>
<h1>GS PRO Admin Center</h1>
<a href="https://${DOMAIN_COC}">Cockpit (服务器后台)</a>
<a href="https://${DOMAIN_PANEL}:${AAPANEL_PORT}">aaPanel</a>
<a href="https://${DOMAIN_NC}">Nextcloud</a>
<a href="https://${DOMAIN_WP}">WordPress</a>
<a href="http://${SERVER_IP}:81">NPM 控制台</a>
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

#######################################################################
# 10. aaPanel 反代 + SSL
#######################################################################

cat >/etc/nginx/sites-available/aapanel.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_PANEL};

    location / {
        proxy_pass http://127.0.0.1:${AAPANEL_PORT};
    }
}
EOF

ln -sf /etc/nginx/sites-available/aapanel.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d "${DOMAIN_PANEL}" -m "${ADMIN_EMAIL}" --agree-	tos --redirect --non-interactive

#######################################################################
# 11. WordPress + SSL
#######################################################################

mkdir -p /var/www/wordpress
if [ ! -f /var/www/wordpress/index.php ]; then
  wget -O /tmp/wp.tgz https://wordpress.org/latest.tar.gz
  tar -xzf /tmp/wp.tgz -C /tmp
  rsync -a /tmp/wordpress/ /var/www/wordpress/
  chown -R www-data:www-data /var/www/wordpress
fi

cat >/etc/nginx/sites-available/wordpress.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN_WP};
    root /var/www/wordpress;
    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
}
EOF

ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

certbot --nginx -d "${DOMAIN_WP}" -m "${ADMIN_EMAIL}" --agree-tos --redirect --non-interactive

#######################################################################
# 12. VNC via noVNC
#######################################################################

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

#######################################################################
# 13. 自动备份
#######################################################################

cat >/usr/local/bin/gs_backup.sh <<'EOF'
#!/usr/bin/env bash
DATE=$(date +"%Y-%m-%d")

tar -czf /backup/nextcloud/nc-$DATE.tar.gz /var/www/nextcloud
tar -czf /backup/docker/npm-$DATE.tar.gz /opt/npm
tar -czf /backup/docker/portainer-$DATE.tar.gz /var/lib/docker/volumes
EOF

chmod +x /usr/local/bin/gs_backup.sh
echo "0 3 * * * root /usr/local/bin/gs_backup.sh" >/etc/cron.d/gs_backup

#######################################################################
# 14. 健康监测
#######################################################################

cat >/usr/local/bin/health_check.sh <<EOF
#!/usr/bin/env bash
SERVICES=(nginx php8.3-fpm redis-server mysql docker)
for S in "\${SERVICES[@]}"; do
  systemctl is-active --quiet \$S || systemctl restart \$S
done
EOF

chmod +x /usr/local/bin/health_check.sh
echo "*/5 * * * * root /usr/local/bin/health_check.sh" >/etc/cron.d/health_check

#######################################################################
# 完成
#######################################################################

echo ""
echo "======================================================="
echo "GS PRO 云平台安装成功！"
echo "管理中心:       https://admin.${MAIN_DOMAIN}"
echo ""
echo "Nextcloud:      https://${DOMAIN_NC}"
echo "WordPress:      https://${DOMAIN_WP}"
echo "Cockpit:        https://${DOMAIN_COC}"
echo "aaPanel:        https://${DOMAIN_PANEL}"
echo "NPM:            http://${SERVER_IP}:81"
echo "VNC Web:        https://${DOMAIN_VNC}"
echo ""
echo "SFTP 用户："
echo "admin   ${PW_ADMIN}"
echo "staff   ${PW_STAFF}"
echo "support ${PW_SUPPORT}"
echo "billing ${PW_BILLING}"
echo ""
echo "所有系统 ✔ SSL, ✔ 反代, ✔ 备份, ✔ 健康监控 已完成"
echo "======================================================="
