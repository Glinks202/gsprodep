#!/usr/bin/env bash
set -e

#############################################
#   GS Cloud Auto Deployment – Part 1
#   Ubuntu 24.04 LTS Full Automation
#   By: Hulin / GS System
#############################################

# === Base Config ===
MAIN_DOMAIN="hulin.pro"
EMAIL="gs@hulin.pro"

# === Subdomains ===
WP_DOMAIN="wp.hulin.pro"
NC_DOMAIN="dri.hulin.pro"
DOC_DOMAIN="doc.hulin.pro"
NPM_DOMAIN="npm.hulin.pro"
COC_DOMAIN="coc.hulin.pro"
PORT_DOMAIN="port.hulin.pro"
ADMIN_DOMAIN="admin.hulin.pro"

# === Passwords ===
ADMIN_PASS="Gaomeilan862447#"
VNC_PASS="862447"

# === SFTP passwords ===
PASS_ADMIN="862447"
PASS_STAFF="862446"
PASS_SUPPORT="862445"
PASS_BILL="862444"

# === Fail2ban Whitelist ===
WHITELIST_IPS=(
"172.56.160.206"   # phone
"172.56.164.101"   # ipad
"176.56.161.108"   # wifi
)

#############################################
banner() { echo -e "\n\033[1;36m==> $1\033[0m"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "请以 root 身份运行脚本"
    exit 1
  fi
}

banner "GS Cloud Auto Deployment – 初始化系统"
need_root

apt update -y
apt install -y sudo curl wget zip unzip git ufw nano software-properties-common

banner "启用防火墙 UFW（含 SSH 白名单）"
ufw allow 22
for ip in "${WHITELIST_IPS[@]}"; do
  ufw allow from "$ip"
done
yes | ufw enable || true

banner "安装基本工具：Docker / Node.js / Python"
apt install -y python3 python3-pip docker.io docker-compose-plugin
systemctl enable docker --now

curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs

banner "创建必要目录结构"
/bin/mkdir -p /gs/{docker,logs,temp,config}
mkdir -p /gs/data/{personal,company,mobile_backup}

chmod -R 755 /gs

banner "安装 Certbot (SSL)"
apt install -y certbot python3-certbot-nginx
#############################################
#   GS Cloud Auto Deployment – Part 2
#   Docker Services: NPM / Portainer / Cockpit
#############################################

banner "部署 Nginx Proxy Manager (npm.hulin.pro)"

mkdir -p /gs/docker/npm
cat >/gs/docker/npm/docker-compose.yml <<EOF
version: "3.8"
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
      - /gs/docker/npm/data:/data
      - /gs/docker/npm/letsencrypt:/etc/letsencrypt
EOF

docker compose -f /gs/docker/npm/docker-compose.yml up -d

banner "部署 Portainer (port.hulin.pro)"

mkdir -p /gs/docker/portainer
docker volume create portainer_data >/dev/null

cat >/gs/docker/portainer/docker-compose.yml <<EOF
version: "3.8"
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: always
    ports:
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
volumes:
  portainer_data:
EOF

docker compose -f /gs/docker/portainer/docker-compose.yml up -d


#############################################
#   Cockpit
#############################################

banner "安装 Cockpit 控制台 (coc.hulin.pro)"

apt install -y cockpit cockpit-networkmanager cockpit-storaged cockpit-packagekit

systemctl enable cockpit
systemctl start cockpit


#############################################
#   Nginx Server Block for Cockpit
#############################################

COC_CONF="/etc/nginx/sites-available/coc.conf"

banner "创建 Cockpit Nginx 反代模板：$COC_CONF"

cat >"$COC_CONF" <<EOF
server {
    listen 80;
    server_name ${COC_DOMAIN};

    location / {
        proxy_pass https://127.0.0.1:9090;
        proxy_ssl_verify off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -sf "$COC_CONF" /etc/nginx/sites-enabled/coc.conf

nginx -t && systemctl reload nginx

#############################################
#   自动申请 SSL for Cockpit
#############################################

banner "申请 SSL for ${COC_DOMAIN}"

certbot --nginx -d "${COC_DOMAIN}" \
  --email "${EMAIL}" --agree-tos --redirect --non-interactive || true

nginx -t && systemctl reload nginx

banner "Cockpit 安装完成：访问 https://${COC_DOMAIN}"
#############################################
#   GS Cloud Auto Deployment – Part 3
#   Nextcloud + OnlyOffice 安装配置
#############################################

banner "安装 Nextcloud（dri.hulin.pro）"

apt install -y apache2 mariadb-server libapache2-mod-php php php-cli php-mysql \
php-zip php-gd php-mbstring php-curl php-xml php-intl php-bz2 php-ldap php-imagick \
php-gmp php-bcmath php-fpm php-redis redis-server

systemctl enable apache2
systemctl enable mariadb

#############################################
#   创建 Nextcloud 数据库
#############################################

banner "创建 Nextcloud 数据库"

mysql <<EOF
CREATE DATABASE nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'ncadmin'@'localhost' IDENTIFIED BY '${ADMIN_PASS}';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'ncadmin'@'localhost';
FLUSH PRIVILEGES;
EOF

#############################################
#   下载 Nextcloud
#############################################

banner "下载并安装 Nextcloud"

cd /var/www
wget https://download.nextcloud.com/server/releases/latest.tar.bz2
tar -xjf latest.tar.bz2
rm -f latest.tar.bz2
chown -R www-data:www-data /var/www/nextcloud
chmod -R 755 /var/www/nextcloud

#############################################
#   Apache 虚拟主机：dri.hulin.pro
#############################################

NC_CONF="/etc/apache2/sites-available/nextcloud.conf"

cat >"$NC_CONF" <<EOF
<VirtualHost *:80>
    ServerName ${NC_DOMAIN}
    DocumentRoot /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>
</VirtualHost>
EOF

ln -sf "$NC_CONF" /etc/apache2/sites-enabled/nextcloud.conf

a2enmod rewrite headers env dir mime ssl proxy proxy_fcgi setenvif
a2ensite nextcloud.conf
systemctl reload apache2


#############################################
#   自动配置 Nextcloud (occ)
#############################################

banner "Nextcloud 首次自动安装"

sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database "mysql" \
  --database-name "nextcloud" \
  --database-user "ncadmin" \
  --database-pass "${ADMIN_PASS}" \
  --admin-user "admin" \
  --admin-pass "${ADMIN_PASS}"


#############################################
#   Nextcloud 目录结构
#############################################

banner "创建 Nextcloud 初始目录结构"

sudo -u www-data mkdir -p /var/www/nextcloud/data/admin/files/{personal,company,mobile_backup}
sudo -u www-data php /var/www/nextcloud/occ files:scan --all


#############################################
#   SSL for Nextcloud
#############################################

banner "申请 SSL for ${NC_DOMAIN}"
certbot --apache -d "${NC_DOMAIN}" \
  --email "${EMAIL}" --agree-tos --redirect --non-interactive || true

systemctl reload apache2


#############################################
#   安装 OnlyOffice Document Server（doc.hulin.pro）
#############################################

banner "部署 OnlyOffice Document Server"

mkdir -p /gs/docker/onlyoffice
cat >/gs/docker/onlyoffice/docker-compose.yml <<EOF
version: "3.8"
services:
  onlyoffice:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice
    restart: always
    ports:
      - "9980:80"
    volumes:
      - /gs/docker/onlyoffice/data:/var/www/onlyoffice/Data
EOF

docker compose -f /gs/docker/onlyoffice/docker-compose.yml up -d


#############################################
#   Nginx 反代：doc.hulin.pro
#############################################

DOC_CONF="/etc/nginx/sites-available/doc.conf"

cat >"$DOC_CONF" <<EOF
server {
    listen 80;
    server_name ${DOC_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:9980;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf "$DOC_CONF" /etc/nginx/sites-enabled/doc.conf

nginx -t && systemctl reload nginx

banner "为 OnlyOffice/DOC 申请 SSL"
certbot --nginx -d "${DOC_DOMAIN}" \
  --email "${EMAIL}" --agree-tos --redirect --non-interactive || true

nginx -t && systemctl reload nginx

banner "Nextcloud & OnlyOffice 安装完成"
#############################################
#   GS Cloud Auto Deployment – Part 4
#   WordPress 安装配置（wp.hulin.pro）
#############################################

banner "安装 WordPress 所需组件"

apt install -y php-fpm php-mysql php-gd php-intl php-xml php-mbstring php-zip php-curl

systemctl enable php8.1-fpm || true
systemctl start php8.1-fpm || true

#############################################
#   创建 WordPress 数据库
#############################################

banner "创建 WordPress 数据库"

mysql <<EOF
CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wpuser'@'localhost' IDENTIFIED BY '${ADMIN_PASS}';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wpuser'@'localhost';
FLUSH PRIVILEGES;
EOF


#############################################
#   下载 WordPress
#############################################

banner "下载 WordPress"

mkdir -p /var/www/wordpress
cd /var/www/wordpress

wget https://wordpress.org/latest.zip
unzip latest.zip
rm -f latest.zip
mv wordpress/* .
rm -rf wordpress

chown -R www-data:www-data /var/www/wordpress
chmod -R 755 /var/www/wordpress


#############################################
#   WordPress Nginx 配置
#############################################

WP_CONF="/etc/nginx/sites-available/wp.conf"

cat >"$WP_CONF" <<EOF
server {
    listen 80;
    server_name ${WP_DOMAIN};

    root /var/www/wordpress;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf "$WP_CONF" /etc/nginx/sites-enabled/wp.conf

nginx -t && systemctl reload nginx


#############################################
#   自动生成 WordPress 配置文件
#############################################

banner "生成 WP 配置文件"

cp /var/www/wordpress/wp-config-sample.php /var/www/wordpress/wp-config.php

sed -i "s/database_name_here/wordpress/" /var/www/wordpress/wp-config.php
sed -i "s/username_here/wpuser/" /var/www/wordpress/wp-config.php
sed -i "s/password_here/${ADMIN_PASS}/" /var/www/wordpress/wp-config.php

WP_SALT=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
sed -i "/AUTH_KEY/d" /var/www/wordpress/wp-config.php
sed -i "/SECURE_AUTH_KEY/d" /var/www/wordpress/wp-config.php
sed -i "41i ${WP_SALT}" /var/www/wordpress/wp-config.php


#############################################
#   初始化 WordPress 管理员账号
#############################################

banner "初始化 WordPress 管理员账号"

cd /var/www/wordpress

sudo -u www-data php wp-cli.phar core install \
  --url="https://${WP_DOMAIN}" \
  --title="GS Cloud WordPress" \
  --admin_user="admin" \
  --admin_password="${ADMIN_PASS}" \
  --admin_email="${EMAIL}" || true


#############################################
#   申请 WordPress SSL
#############################################

banner "申请 SSL for ${WP_DOMAIN}"

certbot --nginx -d "${WP_DOMAIN}" \
  --email "${EMAIL}" --agree-tos --redirect --non-interactive || true

nginx -t && systemctl reload nginx

banner "WordPress 安装完成：访问 https://${WP_DOMAIN}"
#############################################
#   GS Cloud Auto Deployment – Part 5
#   admin.hulin.pro 统一后台（Node.js）
#############################################

banner "部署统一后台：admin.hulin.pro"

mkdir -p /gs/admin
cd /gs/admin

#############################################
#   后端：Node.js API
#############################################

cat >/gs/admin/server.js <<'EOF'
import express from "express";
import os from "os";
import fs from "fs";
import { execSync } from "child_process";

const app = express();
app.use(express.json());

const ADMIN_EMAIL = "gs@hulin.pro";
const ADMIN_PASS = "Gaomeilan862447#";

function checkService(port) {
  try {
    execSync(`nc -z 127.0.0.1 ${port}`);
    return true;
  } catch {
    return false;
  }
}

app.post("/login", (req, res) => {
  const { email, pass } = req.body;
  if (email === ADMIN_EMAIL && pass === ADMIN_PASS) {
    return res.json({ ok: true });
  }
  res.json({ ok: false });
});

app.get("/status", (req, res) => {
  res.json({
    cpu: os.loadavg()[0],
    memory: {
      used: os.totalmem() - os.freemem(),
      total: os.totalmem()
    },
    services: {
      npm: checkService(81),
      portainer: checkService(9443),
      cockpit: checkService(9090),
      nextcloud: checkService(80),
      onlyoffice: checkService(9980),
      wordpress: checkService(80)
    }
  });
});

app.get("/", (req, res) => {
  res.sendFile("/gs/admin/index.html");
});

app.listen(3000, () => console.log("Admin Dashboard running on port 3000"));
EOF


#############################################
#   前端 UI（index.html）
#############################################

cat >/gs/admin/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>GS Unified Admin Panel</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-900 text-white p-6">
  <h1 class="text-3xl font-bold mb-6">GS Unified Admin Panel</h1>

  <div id="loginBox" class="mb-6">
    <input id="email" class="text-black p-2" placeholder="Email">
    <input id="pass" class="text-black p-2" type="password" placeholder="Password">
    <button onclick="login()" class="bg-blue-500 px-4 py-2 ml-2">Login</button>
  </div>

  <div id="panel" class="hidden">
    <h2 class="text-xl font-bold mb-4">System Status</h2>
    <pre id="statusBox" class="bg-gray-800 p-4 rounded"></pre>

    <h2 class="text-xl font-bold mt-6 mb-4">Services</h2>
    <div class="grid grid-cols-2 gap-4">
      <a href="https://npm.hulin.pro" class="bg-gray-700 p-4 rounded">NPM</a>
      <a href="https://dri.hulin.pro" class="bg-gray-700 p-4 rounded">Nextcloud</a>
      <a href="https://doc.hulin.pro" class="bg-gray-700 p-4 rounded">OnlyOffice</a>
      <a href="https://wp.hulin.pro" class="bg-gray-700 p-4 rounded">WordPress</a>
      <a href="https://port.hulin.pro" class="bg-gray-700 p-4 rounded">Portainer</a>
      <a href="https://coc.hulin.pro" class="bg-gray-700 p-4 rounded">Cockpit</a>
    </div>
  </div>

  <script>
    function login() {
      fetch("/login", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({
          email: document.getElementById("email").value,
          pass: document.getElementById("pass").value
        })
      }).then(r=>r.json()).then(d=>{
        if(d.ok){
          document.getElementById("loginBox").classList.add("hidden");
          document.getElementById("panel").classList.remove("hidden");
          loadStatus();
        } else alert("Login failed");
      });
    }

    function loadStatus() {
      fetch("/status").then(r=>r.json()).then(d=>{
        document.getElementById("statusBox").innerText = JSON.stringify(d,null,2);
      });
    }
  </script>
</body>
</html>
EOF


#############################################
#   安装 node modules & 创建 systemd 服务
#############################################

cd /gs/admin
npm init -y
npm install express

cat >/etc/systemd/system/gsadmin.service <<EOF
[Unit]
Description=GS Unified Admin Panel
After=network.target

[Service]
ExecStart=/usr/bin/node /gs/admin/server.js
Restart=always
User=root
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl enable gsadmin
systemctl restart gsadmin


#############################################
#   Nginx 反代 + SSL
#############################################

ADMIN_CONF="/etc/nginx/sites-available/admin.conf"

cat >"$ADMIN_CONF" <<EOF
server {
    listen 80;
    server_name ${ADMIN_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf "$ADMIN_CONF" /etc/nginx/sites-enabled/admin.conf
nginx -t && systemctl reload nginx

certbot --nginx -d "${ADMIN_DOMAIN}" \
  --email "${EMAIL}" --agree-tos --redirect --non-interactive || true

nginx -t && systemctl reload nginx

banner "统一后台安装成功： https://${ADMIN_DOMAIN}"
#############################################
#   GS Cloud Auto Deployment – Part 6
#   Security: SFTP / Fail2ban / SSH Hardening
#############################################

banner "创建 SFTP 安全用户"

add_sftp_user() {
  local user=$1
  local pass=$2

  if ! id "$user" >/dev/null 2>&1; then
    useradd -m -s /usr/sbin/nologin "$user"
    echo "$user:$pass" | chpasswd
    mkdir -p /home/$user/files
    chown -R $user:$user /home/$user
    chmod 700 /home/$user
  fi
}

add_sftp_user "admin"   "${PASS_ADMIN}"
add_sftp_user "staff"   "${PASS_STAFF}"
add_sftp_user "support" "${PASS_SUPPORT}"
add_sftp_user "billing" "${PASS_BILL}"

banner "配置 SFTP 限制（Chroot + 无 Shell）"

sed -i '/Subsystem sftp/d' /etc/ssh/sshd_config
echo "Subsystem sftp internal-sftp" >> /etc/ssh/sshd_config

cat >>/etc/ssh/sshd_config <<EOF

Match Group sftp
    ChrootDirectory /home/%u
    ForceCommand internal-sftp
    X11Forwarding no
    AllowTcpForwarding no
EOF

systemctl restart sshd


#############################################
#   Fail2ban 安装 + 配置
#############################################

banner "安装 Fail2ban"

apt install -y fail2ban

JAIL_CONF="/etc/fail2ban/jail.local"

cat >"$JAIL_CONF" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8  ::1
destemail = ${EMAIL}
sender = ${EMAIL}
backend = auto
bantime = 600
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF

# 添加白名单
for ip in "${WHITELIST_IPS[@]}"; do
  sed -i "/ignoreip/s/$/ ${ip}/" "$JAIL_CONF"
done

systemctl enable fail2ban
systemctl restart fail2ban


#############################################
#   SSH 加固（保留 root 登录 + 密码登录）
#############################################

banner "SSH 加固（保持 root 登录开启）"

sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config

systemctl restart sshd


#############################################
#   防火墙进一步加强
#############################################

banner "强化 UFW 防火墙"

ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 9443
ufw allow 9980
yes | ufw enable || true


#############################################
#   健康检查（自动修复）
#############################################

banner "安装自动修复守护"

cat >/usr/local/bin/gs-health <<'EOF'
#!/bin/bash
# 自动修复 Docker / Nginx / Apache
if ! systemctl is-active --quiet docker; then systemctl restart docker; fi
if ! systemctl is-active --quiet nginx; then systemctl restart nginx; fi
if ! systemctl is-active --quiet apache2; then systemctl restart apache2; fi
EOF

chmod +x /usr/local/bin/gs-health

cat >/etc/systemd/system/gshealth.service <<EOF
[Unit]
Description=GS Health Monitor

[Service]
ExecStart=/usr/local/bin/gs-health
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable gshealth
systemctl restart gshealth

banner "SFTP / Fail2ban / SSH 安全配置完成"
#############################################
#   GS Cloud Auto Deployment – Part 7
#   Auto Reverse Proxy + SSL + Domain Scan
#############################################

banner "自动生成所有子域的反向代理模板"

DOMAINS=(
"${WP_DOMAIN}"
"${NC_DOMAIN}"
"${DOC_DOMAIN}"
"${NPM_DOMAIN}"
"${COC_DOMAIN}"
"${PORT_DOMAIN}"
"${ADMIN_DOMAIN}"
)

create_proxy() {
  local name="$1"
  local port="$2"
  local file="/etc/nginx/sites-available/${name}.conf"

  cat >"$file" <<EOF
server {
    listen 80;
    server_name ${name};

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

  ln -sf "$file" "/etc/nginx/sites-enabled/${name}.conf"
}

# 仅需要 NPM / OnlyOffice / Cockpit / Portainer / Admin
create_proxy "${NPM_DOMAIN}" 81
create_proxy "${COC_DOMAIN}" 9090
create_proxy "${PORT_DOMAIN}" 9443
create_proxy "${ADMIN_DOMAIN}" 3000
create_proxy "${DOC_DOMAIN}" 9980

nginx -t && systemctl reload nginx


#############################################
#   自动 SSL 校验
#############################################

banner "为所有子域申请或更新 SSL"

for dm in "${DOMAINS[@]}"; do
  certbot --nginx -d "${dm}" \
    --email "${EMAIL}" --agree-tos --redirect --non-interactive || true
done

nginx -t && systemctl reload nginx


#############################################
#   域名扫描（提供给 admin.hulin.pro）
#############################################

banner "生成域名扫描工具"

cat >/usr/local/bin/gs-domains <<EOF
#!/bin/bash
echo "{
  \\"wp\\": \\"https://${WP_DOMAIN}\\",
  \\"nextcloud\\": \\"https://${NC_DOMAIN}\\",
  \\"doc\\": \\"https://${DOC_DOMAIN}\\",
  \\"npm\\": \\"https://${NPM_DOMAIN}\\",
  \\"cockpit\\": \\"https://${COC_DOMAIN}\\",
  \\"portainer\\": \\"https://${PORT_DOMAIN}\\",
  \\"admin\\": \\"https://${ADMIN_DOMAIN}\\"
}"
EOF

chmod +x /usr/local/bin/gs-domains


#############################################
#   自动创建并修复数据结构
#############################################

banner "构建公司 / 个人 / 移动资料结构"

mkdir -p /gs/data/{personal,company,mobile_backup}
chmod -R 755 /gs/data

# 写入 Nextcloud 数据
sudo -u www-data mkdir -p /var/www/nextcloud/data/admin/files/{personal,company,mobile_backup}
sudo -u www-data php /var/www/nextcloud/occ files:scan --all


#############################################
#   Nextcloud 权限修复器
#############################################

cat >/usr/local/bin/gs-ncfix <<'EOF'
#!/bin/bash
chown -R www-data:www-data /var/www/nextcloud
chmod -R 755 /var/www/nextcloud
sudo -u www-data php /var/www/nextcloud/occ files:scan --all
EOF

chmod +x /usr/local/bin/gs-ncfix


#############################################
#   Cron 自动化任务
#############################################

banner "安装系统定时任务（cron）"

cat >/etc/cron.d/gscloud <<EOF
SHELL=/bin/bash

# 每日自动更新 SSL
0 3 * * * root certbot renew --quiet && systemctl reload nginx

# 每日 Nextcloud 修复
15 3 * * * root /usr/local/bin/gs-ncfix

# 每日健康检查
*/10 * * * * root /usr/local/bin/gs-health

# 每日域名输出（供后台使用）
0 */2 * * * root /usr/local/bin/gs-domains >/gs/tmp/domains.json
EOF

banner "反代 / SSL / Cron 设置完成"
#############################################
#   GS Cloud Auto Deployment – Part 8
#   Final Check / Permissions / Deployment Report
#############################################

banner "补齐权限与文件结构"

chown -R www-data:www-data /var/www/nextcloud || true
chmod -R 755 /var/www/nextcloud || true

chown -R www-data:www-data /var/www/wordpress || true
chmod -R 755 /var/www/wordpress || true

chmod -R 755 /gs || true


#############################################
#   重启所有服务
#############################################

banner "重启所有核心服务"

systemctl restart nginx || true
systemctl restart apache2 || true
systemctl restart docker || true
systemctl restart fail2ban || true
systemctl restart sshd || true
systemctl restart gsadmin || true
systemctl restart gshealth || true


#############################################
#   可用性检测
#############################################

banner "检测各子域是否就绪（DNS + 80/443）"

check_domain() {
  local domain=$1
  if ping -c 1 -W 2 "$domain" >/dev/null 2>&1; then
    echo "✔ ${domain} 正常"
  else
    echo "✘ ${domain} 不可达（可能 DNS 刚更新）"
  fi
}

check_domain "${WP_DOMAIN}"
check_domain "${NC_DOMAIN}"
check_domain "${DOC_DOMAIN}"
check_domain "${NPM_DOMAIN}"
check_domain "${COC_DOMAIN}"
check_domain "${PORT_DOMAIN}"
check_domain "${ADMIN_DOMAIN}"


#############################################
#   最终输出部署报告
#############################################

banner "🎉 GS Cloud 自动部署完成！"

cat <<EOF

==============================================
🔥 GS Cloud Deployment Successfully Finished
==============================================

🌐 主域名：
  https://${MAIN_DOMAIN}

📌 子域后台：
  WordPress:      https://${WP_DOMAIN}
  Nextcloud:      https://${NC_DOMAIN}
  OnlyOffice:     https://${DOC_DOMAIN}
  NPM:            https://${NPM_DOMAIN}
  Cockpit:        https://${COC_DOMAIN}
  Portainer:      https://${PORT_DOMAIN}
  Admin Panel:    https://${ADMIN_DOMAIN}

🔐 全局管理员账号：
  Email:    ${EMAIL}
  Password: ${ADMIN_PASS}

📂 Nextcloud 初始结构：
  /personal
  /company
  /mobile_backup

👤 SFTP 用户（已添加）：
  admin    / ${PASS_ADMIN}
  staff    / ${PASS_STAFF}
  support  / ${PASS_SUPPORT}
  billing  / ${PASS_BILL}

🔒 Fail2ban 白名单：
EOF

for ip in "${WHITELIST_IPS[@]}"; do
  echo "  - ${ip}"
done

cat <<EOF

🧩 自动化任务：
  ✓ SSL 自动续期
  ✓ Docker/Apache/Nginx 自愈
  ✓ Nextcloud 权限修复
  ✓ 域名扫描更新

📦 数据目录：/gs/data/

==============================================
✨ 部署脚本执行完毕：gspro.sh ALL DONE
==============================================

EOF
