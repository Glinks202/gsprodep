#!/usr/bin/env bash
set -e

###############################################################
#   G S P R O   — FULL AUTO DEPLOY SYSTEM
#   Ubuntu 24.04 LTS — One-Key Full System Deployment
#   Includes:
#   - Cleanup old environment
#   - Docker + Compose
#   - WordPress Multisite
#   - Nextcloud
#   - OnlyOffice
#   - noVNC
#   - Portainer
#   - Fail2ban + Whitelist
#   - Nginx Proxy Manager + SSL
#   - Domain auto mapping
###############################################################

echo "===================================================="
echo " 🟦 GS PRO — 全自动部署系统初始化"
echo "===================================================="

###############################################################
# 0. 环境检查
###############################################################
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 必须使用 root 运行"
    exit 1
fi

UBU=$(lsb_release -rs | cut -d'.' -f1)
if [ "$UBU" -ne 24 ]; then
    echo "❌ 必须运行在 Ubuntu 24.04 LTS"
    exit 1
fi

echo "✔ 系统版本验证通过：Ubuntu 24.04 LTS"

###############################################################
# 1. 用户参数（你的固定参数）
###############################################################
MAIN_IP="82.180.137.120"
MAIN_DOMAIN="hulin.pro"
EMAIL="gs@hulin.pro"

VNC_PASS="862447"
AAPANEL_PORT="8812"

declare -A USERS=(
["admin"]="862447"
["staff"]="862446"
["support"]="862445"
["billing"]="862444"
)

# 需要部署的域名
DOMAINS=(
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

# 服务端口映射
declare -A PORTMAP=(
["hulin.pro"]="9001"
["ezglinns.com"]="9001"
["hulin.bz"]="9001"
["wp.hulin.pro"]="9001"
["admin.hulin.pro"]="9001"
["doc.hulin.pro"]="9000"
["dri.hulin.pro"]="9001"
["coc.hulin.pro"]="9090"
["vnc.hulin.pro"]="6080"
["npm.hulin.pro"]="81"
)

echo "✔ 基础参数已加载"

###############################################################
# 2. 清理旧环境（Docker/NPM/Fail2ban/Nginx）
###############################################################
echo "===================================================="
echo " 🟧 清理旧环境（避免冲突）"
echo "===================================================="

systemctl stop nginx || true
systemctl stop docker || true
systemctl stop fail2ban || true

apt remove -y docker docker.io containerd runc || true
rm -rf /var/lib/docker /var/lib/containerd || true
rm -rf /opt/npm || true
rm -rf /etc/fail2ban/jail.local || true
rm -rf /etc/nginx/sites-enabled/* || true
rm -rf /etc/nginx/sites-available/* || true

echo "✔ 旧环境清理完成"

###############################################################
# 3. 更新系统 & 安装必要工具
###############################################################
echo "===================================================="
echo " 🟧 更新系统 & 安装基础组件"
echo "===================================================="

apt update -y
apt upgrade -y
apt install -y \
    curl wget git unzip htop ufw nano jq net-tools dnsutils sqlite3 \
    software-properties-common apt-transport-https ca-certificates gnupg

echo "✔ 系统工具安装完成"

###############################################################
# 4. 写入 /etc/hosts（内部解析）
###############################################################
echo "===================================================="
echo " 🟧 写入内部域名解析 /etc/hosts"
echo "===================================================="

cat >/etc/hosts <<EOF
127.0.0.1 localhost
$MAIN_IP hulin.pro
$MAIN_IP ezglinns.com
$MAIN_IP hulin.bz
$MAIN_IP wp.hulin.pro
$MAIN_IP admin.hulin.pro
$MAIN_IP doc.hulin.pro
$MAIN_IP dri.hulin.pro
$MAIN_IP coc.hulin.pro
$MAIN_IP vnc.hulin.pro
$MAIN_IP npm.hulin.pro
EOF

echo "✔ /etc/hosts 写入完成"

###############################################################
# 5. DNS 检查（确保域名正确解析）
###############################################################
echo "===================================================="
echo " 🟧 检查 DNS 解析状态"
echo "===================================================="

for d in "${DOMAINS[@]}"; do
    IP=$(dig +short "$d" | head -n 1)
    if [ "$IP" != "$MAIN_IP" ]; then
        echo "⚠ 警告：$d 未正确指向 $MAIN_IP (当前: $IP)"
    else
        echo "✔ $d DNS 正常"
    fi
done

echo "===================================================="
echo " 🟩 第 1/6 段结束"
echo "===================================================="
###############################################################
# 6. 安装 Docker（含 containerd 冲突修复）
###############################################################

echo "===================================================="
echo " 🟦 安装 Docker / Docker Compose"
echo "===================================================="

# 强制卸载冲突组件
apt remove -y containerd.io containerd docker.io docker runc || true
rm -rf /var/lib/containerd || true

apt update -y
apt install -y ca-certificates curl gnupg lsb-release software-properties-common

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker --now
echo "✔ Docker 安装完成：$(docker --version)"

###############################################################
# 7. 安装 Portainer（可视化管理 Docker）
###############################################################

echo "===================================================="
echo " 🟦 安装 Portainer"
echo "===================================================="

docker volume create portainer_data >/dev/null 2>&1 || true

docker run -d \
  --name portainer \
  --restart=always \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest

echo "✔ Portainer 运行中（待反代：https://port.hulin.pro）"

###############################################################
# 8. 安装 Nginx Proxy Manager (NPM)
###############################################################

echo "===================================================="
echo " 🟧 安装 Nginx Proxy Manager (NPM)"
echo "===================================================="

mkdir -p /opt/npm

cat >/opt/npm/docker-compose.yml <<EOF
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
      - /opt/npm/data:/data
      - /opt/npm/letsencrypt:/etc/letsencrypt
EOF

cd /opt/npm
docker compose up -d

sleep 10
echo "✔ NPM 已启动：http://npm.hulin.pro:81"

###############################################################
# 9. 自动更新 NPM 管理员账号 & 密码
###############################################################

echo "===================================================="
echo " 🟧 配置 NPM 管理员账号"
echo "===================================================="

NPM_ADMIN_EMAIL="gs@hulin.pro"
NPM_ADMIN_PASS="Gaomeilan862447#"

DB="/opt/npm/data/database.sqlite"

if [ ! -f "$DB" ]; then
    echo "⚠ database.sqlite 未生成，等待 5 秒"
    sleep 5
fi

# NPM 密码 Bcrypt：密码 = Gaomeilan862447#
NPM_BCRYPT_PASS="\$2y\$10\$WUwW7YcHkRkNvztNFVQVwOfGc7YCOUMIqFZ3VAb9YSEuxsjjXNMTK"

docker exec npm bash -c "
sqlite3 /data/database.sqlite <<SQL
UPDATE user SET email='$NPM_ADMIN_EMAIL', name='Administrator' WHERE id=1;
UPDATE user SET password='$NPM_BCRYPT_PASS' WHERE id=1;
SQL
"

echo "✔ NPM 管理员设置完成：$NPM_ADMIN_EMAIL / $NPM_ADMIN_PASS"

###############################################################
# 10. 获取 NPM API Token（用于自动 SSL + 自动反代）
###############################################################

echo "===================================================="
echo " 🟦 获取 NPM API Token"
echo "===================================================="

TOKEN_PATH="/opt/npm/data/nginx/proxy_host_token"
if [ -f "$TOKEN_PATH" ]; then
    NPM_TOKEN=$(cat "$TOKEN_PATH")
else
    echo "⚠ Token 未生成，等待 5 秒"
    sleep 5
    NPM_TOKEN=$(cat "$TOKEN_PATH" 2>/dev/null || echo "")
fi

if [ -z "$NPM_TOKEN" ]; then
    echo "❌ 无法读取 NPM Token（无法自动反代/SSL）"
    echo "请稍后再运行脚本：bash gspro.sh"
    exit 1
fi

echo "✔ NPM Token 读取成功"

# 为下一阶段导出变量
export NPM_TOKEN
export NPM_API="http://127.0.0.1:81/api"
export AUTH="Authorization: Bearer ${NPM_TOKEN}"

echo "===================================================="
echo " 🟩 第 2/6 段结束"
echo "===================================================="
###############################################################
# 11. 安装 MariaDB（WordPress + Nextcloud 使用）
###############################################################

echo "===================================================="
echo " 🟦 安装 MariaDB（数据库）"
echo "===================================================="

apt install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb

# 设置 root 免密码（本地 socket 登录）
mysql -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('');
FLUSH PRIVILEGES;
EOF

echo "✔ MariaDB 已安装"

###############################################################
# 12. 为 WordPress & Nextcloud 创建数据库
###############################################################

echo "===================================================="
echo " 🟦 创建 WordPress / Nextcloud 数据库"
echo "===================================================="

mysql -uroot <<EOF
CREATE DATABASE IF NOT EXISTS wp DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS nextcloud DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'wpuser'@'localhost' IDENTIFIED BY 'wp_pass';
CREATE USER IF NOT EXISTS 'ncuser'@'localhost' IDENTIFIED BY 'nc_pass';

GRANT ALL PRIVILEGES ON wp.* TO 'wpuser'@'localhost';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'ncuser'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "✔ 数据库已就绪"

###############################################################
# 13. 安装 Redis（Nextcloud 缓存）
###############################################################

echo "===================================================="
echo " 🟦 安装 Redis"
echo "===================================================="

apt install -y redis
systemctl enable redis --now

echo "✔ Redis 已安装"

###############################################################
# 14. 部署 Nextcloud（端口 9001）
###############################################################

echo "===================================================="
echo " 🟩 部署 Nextcloud"
echo "===================================================="

mkdir -p /opt/nextcloud

cat >/opt/nextcloud/docker-compose.yml <<EOF
version: "3.9"
services:
  nextcloud:
    image: nextcloud:27
    container_name: nextcloud
    restart: always
    ports:
      - "9001:80"
    volumes:
      - /opt/nextcloud/html:/var/www/html
    environment:
      MYSQL_HOST: localhost
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: ncuser
      MYSQL_PASSWORD: nc_pass
      REDIS_HOST: localhost

EOF

cd /opt/nextcloud
docker compose up -d

echo "✔ Nextcloud 已启动 → 待反代为：https://dri.hulin.pro"

###############################################################
# 15. 部署 OnlyOffice Document Server（端口 9000）
###############################################################

echo "===================================================="
echo " 🟩 部署 OnlyOffice（文档编辑）"
echo "===================================================="

mkdir -p /opt/onlyoffice

cat >/opt/onlyoffice/docker-compose.yml <<EOF
version: "3.9"
services:
  onlyoffice:
    image: onlyoffice/documentserver
    container_name: onlyoffice
    restart: always
    ports:
      - "9000:80"
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: "nextcloud-secret"
EOF

cd /opt/onlyoffice
docker compose up -d

echo "✔ OnlyOffice 运行中 → https://doc.hulin.pro"

###############################################################
# 16. 部署 noVNC（端口 6080）
###############################################################

echo "===================================================="
echo " 🟩 部署 noVNC（Web 远程桌面）"
echo "===================================================="

mkdir -p /opt/novnc

cat >/opt/novnc/docker-compose.yml <<EOF
version: "3.9"
services:
  novnc:
    image: theasp/novnc:latest
    container_name: novnc
    restart: always
    ports:
      - "6080:8080"
    environment:
      VNC_PASSWD: "862447"
EOF

cd /opt/novnc
docker compose up -d

echo "✔ noVNC 运行中 → https://vnc.hulin.pro"

###############################################################
# 17. 安装 WordPress（基础单站，后续升级为多站点）
###############################################################

echo "===================================================="
echo " 🟧 安装 WordPress（基础版本）"
echo "===================================================="

mkdir -p /var/www/html

wget -q https://wordpress.org/latest.zip -O /tmp/wp.zip
unzip -q /tmp/wp.zip -d /tmp

rsync -a /tmp/wordpress/ /var/www/html/

chown -R www-data:www-data /var/www/html

echo "✔ WordPress 基础版本已安装 → https://hulin.pro"

###############################################################
# 18. 写入 wp-config.php（为多站点准备）
###############################################################

echo "===================================================="
echo " 🟧 写入 wp-config.php"
echo "===================================================="

cat >/var/www/html/wp-config.php <<EOF
<?php
define( 'DB_NAME', 'wp' );
define( 'DB_USER', 'wpuser' );
define( 'DB_PASSWORD', 'wp_pass' );
define( 'DB_HOST', 'localhost' );

define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

define( 'AUTH_KEY',         '$(openssl rand -hex 32)' );
define( 'SECURE_AUTH_KEY',  '$(openssl rand -hex 32)' );
define( 'LOGGED_IN_KEY',    '$(openssl rand -hex 32)' );
define( 'NONCE_KEY',        '$(openssl rand -hex 32)' );
define( 'AUTH_SALT',        '$(openssl rand -hex 32)' );
define( 'SECURE_AUTH_SALT', '$(openssl rand -hex 32)' );
define( 'LOGGED_IN_SALT',   '$(openssl rand -hex 32)' );
define( 'NONCE_SALT',       '$(openssl rand -hex 32)' );

\$table_prefix = 'wp_';

define( 'WP_DEBUG', false );

/* 多站点将在后续脚本写入 */
EOF

echo "✔ wp-config.php 基础配置完成"

echo "===================================================="
echo " 🟩 第 3/6 段结束"
echo "===================================================="
###############################################################
# 17. 安装 WordPress（多站点架构）
###############################################################

echo "===================================================="
echo " 🟩 安装 WordPress 多站点"
echo "===================================================="

apt install -y php php-fpm php-cli php-mysql php-gd php-xml php-curl php-zip php-mbstring php-intl

mkdir -p /var/www/wordpress
cd /var/www/wordpress

# 下载 WP
wget -q https://wordpress.org/latest.zip
unzip -q latest.zip
mv wordpress/* .
rm -rf wordpress latest.zip

# 创建数据库
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS wp;
EOF

cp wp-config-sample.php wp-config.php

# 写入数据库配置
sed -i "s/database_name_here/wp/" wp-config.php
sed -i "s/username_here/root/" wp-config.php
sed -i "s/password_here//" wp-config.php

###############################################################
# 18. 写入 WordPress MULTISITE 配置
###############################################################

cat >>wp-config.php <<EOF

/* Multisite */
define('MULTISITE', true);
define('SUBDOMAIN_INSTALL', true);
define('DOMAIN_CURRENT_SITE', 'hulin.pro');
define('PATH_CURRENT_SITE', '/');
define('SITE_ID_CURRENT_SITE', 1);
define('BLOG_ID_CURRENT_SITE', 1);

EOF

echo "✔ WordPress 多站点配置写入完成"

###############################################################
# 19. 配置 Nginx + PHP-FPM（端口 9001）
###############################################################

cat >/etc/nginx/sites-available/wordpress.conf <<EOF
server {
    listen 9001;
    server_name hulin.pro ezglinns.com hulin.bz wp.hulin.pro admin.hulin.pro;

    root /var/www/wordpress;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
    }
}
EOF

ln -sf /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/wordpress.conf

systemctl restart nginx
systemctl restart php*-fpm.service || true

echo "✔ WordPress 主站 / 子站 Nginx 配置完成"

###############################################################
# 20. 自动写入 WordPress 子站（ezglinns.com / hulin.bz）
###############################################################

echo "===================================================="
echo " 🟩 写入 WordPress 多站点子站"
echo "===================================================="

# WP CLI 安装
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

cd /var/www/wordpress

# 安装 WordPress 主站
wp core install \
  --url="https://hulin.pro" \
  --title="Hulin Pro" \
  --admin_user="admin" \
  --admin_email="$EMAIL" \
  --admin_password="Gaomeilan862447#" \
  --skip-email --allow-root

# 启用多站
wp core multisite-convert --allow-root

# 子站：ezglinns.com
wp site create \
  --slug="ezglinns.com" \
  --title="EZ GLINNS" \
  --email="$EMAIL" \
  --allow-root

# 子站：hulin.bz
wp site create \
  --slug="hulin.bz" \
  --title="Hulin BZ" \
  --email="$EMAIL" \
  --allow-root

echo "✔ WordPress 多站点子站创建成功"

###############################################################
# 21. 自动创建 NPM 反代（WordPress）
###############################################################

echo "===================================================="
echo " 🟧 自动创建 WordPress 反代"
echo "===================================================="

WP_HOSTS=(
"hulin.pro"
"wp.hulin.pro"
"admin.hulin.pro"
"ezglinns.com"
"hulin.bz"
)

for DOMAIN in "${WP_HOSTS[@]}"; do
    echo "→ 创建反代：$DOMAIN → 127.0.0.1:9001"

    CREATE_JSON=$(cat <<EOF
{
  "domain_names": ["$DOMAIN"],
  "scheme": "http",
  "forward_host": "127.0.0.1",
  "forward_port": 9001,
  "certificate_id": "new",
  "ssl_forced": true
}
EOF
)

    curl -s -H "Content-Type: application/json" \
         -H "$AUTH" \
         -X POST "$NPM_API/nginx/proxy-hosts" \
         -d "$CREATE_JSON"
done

echo "✔ WordPress 反代已创建"

###############################################################
# 22. 自动申请 SSL（WordPress 多站点）
###############################################################

echo "===================================================="
echo " 🟩 自动申请 SSL（WordPress 全站）"
echo "===================================================="

for DOMAIN in "${WP_HOSTS[@]}"; do
    echo "→ SSL：$DOMAIN"

    SSL_REQ=$(cat <<EOF
{
  "domain_names": ["$DOMAIN"],
  "email": "$EMAIL",
  "provider": "letsencrypt"
}
EOF
)

    curl -s -H "$AUTH" -H "Content-Type: application/json" \
         -X POST "$NPM_API/nginx/certificates" \
         -d "$SSL_REQ"
done

echo "✔ WordPress SSL 全部申请完成"

echo "===================================================="
echo " 🟩 第 4/6 段结束"
echo "===================================================="
###############################################################
# 23. 部署 Nextcloud（dri.hulin.pro）
###############################################################

echo "===================================================="
echo " 🟦 部署 Nextcloud（含数据库 + 自动配置）"
echo "===================================================="

docker stop nextcloud 2>/dev/null || true
docker rm nextcloud 2>/dev/null || true
docker stop ncdb 2>/dev/null || true
docker rm ncdb 2>/dev/null || true

docker network create cloudnet 2>/dev/null || true

# MySQL / MariaDB
docker run -d --name ncdb \
  --network cloudnet \
  -e MYSQL_ROOT_PASSWORD="Gaomeilan862447#" \
  -e MYSQL_DATABASE="nextcloud" \
  -e MYSQL_USER="ncuser" \
  -e MYSQL_PASSWORD="Gaomeilan862447#" \
  mariadb:10.6

# Nextcloud 主体
docker run -d --name nextcloud \
  --network cloudnet \
  -v /var/lib/nextcloud:/var/www/html \
  nextcloud

###############################################################
# 24. 部署 OnlyOffice（doc.hulin.pro）
###############################################################

echo "===================================================="
echo " 🟦 部署 OnlyOffice 文档服务器"
echo "===================================================="

docker stop onlyoffice 2>/dev/null || true
docker rm onlyoffice 2>/dev/null || true

docker run -d --name onlyoffice \
  -p 9003:80 \
  onlyoffice/documentserver

###############################################################
# 25. 部署 Portainer（port.hulin.pro）
###############################################################

echo "===================================================="
echo " 🟦 部署 Portainer 管理面板"
echo "===================================================="

docker stop portainer 2>/dev/null || true
docker rm portainer 2>/dev/null || true

docker volume create portainer_data 2>/dev/null || true
docker run -d -p 9000:9000 \
  --name portainer \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce

###############################################################
# 26. 部署 noVNC（vnc.hulin.pro）
###############################################################

echo "===================================================="
echo " 🟦 部署 noVNC"
echo "===================================================="

docker stop novnc 2>/dev/null || true
docker rm novnc 2>/dev/null || true

docker run -d \
  -p 6080:80 \
  --name novnc \
  dorowu/ubuntu-desktop-lxde-vnc

###############################################################
# 27. NPM 自动反代（全部后台）
###############################################################

echo "===================================================="
echo " 🟧 自动反代：Nextcloud / OnlyOffice / Portainer / VNC"
echo "===================================================="

SERVICES=(
"dri.hulin.pro|127.0.0.1|8080"
"doc.hulin.pro|127.0.0.1|9003"
"port.hulin.pro|127.0.0.1|9000"
"vnc.hulin.pro|127.0.0.1|6080"
)

for S in "${SERVICES[@]}"; do
    DOMAIN=$(echo $S | cut -d"|" -f1)
    HOST=$(echo $S | cut -d"|" -f2)
    PORT=$(echo $S | cut -d"|" -f3)

    echo "→ 创建反代：$DOMAIN → $HOST:$PORT"

    JSON=$(cat <<EOF
{
  "domain_names": ["$DOMAIN"],
  "scheme": "http",
  "forward_host": "$HOST",
  "forward_port": $PORT,
  "certificate_id": "new",
  "ssl_forced": true
}
EOF
)

    curl -s -H "Content-Type: application/json" \
         -H "$AUTH" \
         -X POST "$NPM_API/nginx/proxy-hosts" \
         -d "$JSON"
done

###############################################################
# 28. 自动申请 SSL（后台）
###############################################################

echo "===================================================="
echo " 🟩 自动申请 SSL（Nextcloud / Portainer / VNC）"
echo "===================================================="

SSL_DOMAINS=(
"doc.hulin.pro"
"dri.hulin.pro"
"port.hulin.pro"
"vnc.hulin.pro"
)

for DOMAIN in "${SSL_DOMAINS[@]}"; do
  echo "→ SSL：$DOMAIN"

  SSL_JSON=$(cat <<EOF
{
  "domain_names": ["$DOMAIN"],
  "email": "$EMAIL",
  "provider": "letsencrypt"
}
EOF
)

  curl -s -H "$AUTH" -H "Content-Type: application/json" \
       -X POST "$NPM_API/nginx/certificates" \
       -d "$SSL_JSON"
done

###############################################################
# 29. Fail2ban（自动白名单）
###############################################################

echo "===================================================="
echo " 🟩 Fail2ban + 白名单"
echo "===================================================="

apt install -y fail2ban

cat >/etc/fail2ban/jail.d/whitelist.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 172.56.160.206 172.56.164.101 176.56.161.108
EOF

systemctl restart fail2ban

echo "✔ 已加入白名单：手机 + iPad + WiFi"

echo "===================================================="
echo " 🟩 第 5/6 段完成"
echo "===================================================="
###############################################################
# 30. 生成版本号 & 写入
###############################################################

VERSION="v$(date +%Y%m%d%H%M)"
echo "$VERSION" >/root/gspro_version.txt
echo "生成版本号：$VERSION"


###############################################################
# 31. 清理旧日志 & 重启核心服务
###############################################################

echo "===================================================="
echo " 🟦 清理无用容器与缓存"
echo "===================================================="

docker system prune -af
apt autoremove -y
apt autoclean -y

systemctl restart nginx
docker restart npm 2>/dev/null || true


###############################################################
# 32. 域名连通性检测
###############################################################

echo "===================================================="
echo " 🟩 域名 DNS & HTTP 探测"
echo "===================================================="

DOMAINS=(
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

for D in "${DOMAINS[@]}"; do
    echo -e "\n🔎 检查：$D"
    DNS=$(dig +short $D)
    echo "  • DNS: $DNS"

    HTTP=$(curl -I -s --max-time 3 https://$D | head -n1)
    echo "  • HTTP: $HTTP"
done


###############################################################
# 33. 总控台信息输出
###############################################################

echo "===================================================="
echo " 🔰 你的全系统后台总表（自动生成）"
echo "===================================================="

cat <<EOF

=========================  管理入口  =========================

🌐 WordPress 超管（多站点）
   https://wp.hulin.pro/wp-admin/network/
   用户：admin
   密码：Gaomeilan862447#

🌐 主站点（展示页）
   https://hulin.pro

🌐 子站点
   https://ezglinns.com
   https://hulin.bz

📦 Nextcloud（私人云盘）
   https://dri.hulin.pro

📝 OnlyOffice（Word/Excel/PDF 在线编辑）
   https://doc.hulin.pro

🖥 Portainer（Docker 管理）
   https://port.hulin.pro

🖥 Cockpit（系统面板）
   https://coc.hulin.pro:9090

🔍 noVNC（浏览器远程桌面）
   https://vnc.hulin.pro

🌐 Nginx Proxy Manager（反代/SSL）
   https://npm.hulin.pro
   邮箱：gs@hulin.pro
   用户：admin
   密码：Gaomeilan862447#

==============================================================
EOF


###############################################################
# 34. 自动 Push 到 GitHub（使用 SSH）
###############################################################

echo "===================================================="
echo " 🟩 自动推送 gspro.sh → GitHub 仓库"
echo "===================================================="

cd /root/gsprodep || {
    echo "❌ 未找到仓库：/root/gsprodep"
    exit 1
}

cp /root/gspro.sh /root/gsprodep/gspro.sh

git add .
git commit -m "Auto update $VERSION"
git push origin main

echo "✔ GitHub 更新完成：$VERSION"



###############################################################
# 35. 结束
###############################################################

echo "===================================================="
echo " 🟩 gspro.sh 全流程完成！"
echo "===================================================="
echo "可以重新执行：  bash <(curl -s https://raw.githubusercontent.com/Glinks202/gsprodep/main/gspro.sh)"
