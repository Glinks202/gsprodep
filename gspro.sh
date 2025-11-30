#!/usr/bin/env bash
# gspro.sh — G 的一键全自动部署（Ubuntu 24.04 LTS）
# 组件：Docker/Compose + NPM + Nextcloud + OnlyOffice + WordPress(单站) + WP Multisite(总后台)
#       + MariaDB + Portainer + noVNC 桌面 + Cockpit + SFTP(chroot) + UFW + Fail2ban
# NPM API 自动创建全部 Proxy Host + 签发 SSL；若失败则打印手动清单。

set -euo pipefail

# ========= 你的定制 =========
IPV4_PUBLIC="82.180.137.120"
EMAIL_ACME="gs@hulin.pro"
TZ="America/New_York"

# 主域 & 子域
DOM_MAIN="hulin.pro"
DOM_WP="wp.hulin.pro"            # WordPress 单站（公司官网/博客用）
DOM_NC="dri.hulin.pro"           # Nextcloud
DOM_DOC="doc.hulin.pro"          # OnlyOffice
DOM_COCKPIT="coc.hulin.pro"      # Cockpit
DOM_NPM="npm.hulin.pro"          # NPM 后台
DOM_PORTAINER="port.hulin.pro"   # Portainer
DOM_VNC="vnc.hulin.pro"          # noVNC 桌面
DOM_AAPANEL="panel.hulin.pro"    # aaPanel（你之后装）端口见下
AAPANEL_PORT="8812"

# WP Multisite 总后台 + 统一管理的独立域名
DOM_ADMIN="admin.hulin.pro"
DOM_SITES=("ezglinns.com" "gsliberty.com")   # 后台添加站点时使用这些域名

# 账户/口令
VNC_PASS="862447"
declare -A SFTP_PW=(
  [admin]="862447"
  [staff]="862446"
  [support]="862445"
  [billing]="862444"
)
MOBILE_IPS=("172.56.160.206" "172.56.164.101" "176.56.161.108")

# ========= 通用工具 =========
log(){ echo -e "\n\033[1;36m==> $*\033[0m"; }
need_root(){ [ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }; }

apt_setup(){
  log "更新系统并安装基础工具"
  apt-get update -y
  apt-get install -y curl jq ca-certificates gnupg lsb-release ufw sqlite3 fail2ban cockpit
  systemctl enable --now cockpit.socket || true
}

docker_setup(){
  if ! command -v docker >/dev/null 2>&1; then
    log "安装 Docker & Compose"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) stable" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
  fi
  docker network create proxy >/dev/null 2>&1 || true
}

ufw_fail2ban_setup(){
  log "配置 UFW（22/80/81/443/9090/${AAPANEL_PORT}）+ Fail2ban（含你的白名单）"
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 81/tcp || true
  ufw allow 443/tcp || true
  ufw allow 9090/tcp || true
  ufw allow ${AAPANEL_PORT}/tcp || true
  yes | ufw enable || true

  # Fail2ban 基本 ssh 防护 + 白名单
  cat >/etc/fail2ban/jail.d/ssh.local <<'J'
[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
J
  # 白名单
  :> /etc/fail2ban/ignoreip.local
  echo "127.0.0.1/8 ::1" >> /etc/fail2ban/ignoreip.local
  for ip in "${MOBILE_IPS[@]}"; do echo "$ip" >> /etc/fail2ban/ignoreip.local; done
  systemctl restart fail2ban || true
}

layout_dirs(){
  log "创建目录结构 /opt/* /data/*"
  mkdir -p \
    /opt/npm/data /opt/npm/letsencrypt \
    /opt/nextcloud/{html,db} \
    /opt/onlyoffice/data \
    /opt/wordpress/{html,db} \
    /opt/portainer/data \
    /opt/vnc \
    /opt/wpms/{html,db} \
    /data/sftp
}

compose_files(){
  log "生成 docker-compose 文件"

  # NPM
  cat >/opt/npm/docker-compose.yml <<'YML'
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports: ["80:80","81:81","443:443"]
    volumes:
      - /opt/npm/data:/data
      - /opt/npm/letsencrypt:/etc/letsencrypt
    networks: [proxy]
networks: { proxy: { external: true } }
YML

  # Nextcloud
  cat >/opt/nextcloud/docker-compose.yml <<'YML'
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      - MARIADB_ROOT_PASSWORD=autoRoot123!@#
      - MARIADB_DATABASE=nextcloud
      - MARIADB_USER=ncuser
      - MARIADB_PASSWORD=autoDbPass123!@#
    volumes:
      - /opt/nextcloud/db:/var/lib/mysql
    networks: [proxy]

  web:
    image: nextcloud:28-apache
    restart: unless-stopped
    environment:
      - MYSQL_HOST=db
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=ncuser
      - MYSQL_PASSWORD=autoDbPass123!@#
    volumes:
      - /opt/nextcloud/html:/var/www/html
    depends_on: [db]
    networks: [proxy]
    expose: ["8080"]
networks: { proxy: { external: true } }
YML

  # OnlyOffice
  cat >/opt/onlyoffice/docker-compose.yml <<'YML'
services:
  doc:
    image: onlyoffice/documentserver
    restart: unless-stopped
    environment:
      - JWT_ENABLED=true
      - JWT_SECRET=autoOnlyJWT_123456
    networks: [proxy]
    expose: ["80"]
networks: { proxy: { external: true } }
YML

  # WordPress 单站
  cat >/opt/wordpress/docker-compose.yml <<'YML'
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      - MARIADB_ROOT_PASSWORD=autoRootWP!@#
      - MARIADB_DATABASE=wordpress
      - MARIADB_USER=wpuser
      - MARIADB_PASSWORD=autoWpPass!@#
    volumes:
      - /opt/wordpress/db:/var/lib/mysql
    networks: [proxy]

  wp:
    image: wordpress:6-apache
    restart: unless-stopped
    environment:
      - WORDPRESS_DB_HOST=db
      - WORDPRESS_DB_USER=wpuser
      - WORDPRESS_DB_PASSWORD=autoWpPass!@#
      - WORDPRESS_DB_NAME=wordpress
    volumes:
      - /opt/wordpress/html:/var/www/html
    depends_on: [db]
    networks: [proxy]
    expose: ["80"]
networks: { proxy: { external: true } }
YML

  # WP Multisite（admin.hulin.pro 为主站；其它域名作为网络站点）
  cat >/opt/wpms/docker-compose.yml <<YML
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      - MARIADB_ROOT_PASSWORD=wpmsRoot_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 14)
      - MARIADB_DATABASE=wpms
      - MARIADB_USER=wpmsu
      - MARIADB_PASSWORD=wpmsPass_$(tr -dc A-Za-z0-9 </dev/urandom | head -c 14)
    volumes:
      - /opt/wpms/db:/var/lib/mysql
    networks: [proxy]

  wpms:
    image: wordpress:6-apache
    restart: unless-stopped
    environment:
      - WORDPRESS_DB_HOST=db
      - WORDPRESS_DB_NAME=wpms
      - WORDPRESS_DB_USER=wpmsu
      - WORDPRESS_DB_PASSWORD=\${MARIADB_PASSWORD:-wpmsPass_fallback}
      - TZ=${TZ}
      - WORDPRESS_CONFIG_EXTRA=
        define('WP_ALLOW_MULTISITE', true);
        define('MULTISITE', true);
        define('SUBDOMAIN_INSTALL', false);
        define('DOMAIN_CURRENT_SITE', '${DOM_ADMIN}');
        define('PATH_CURRENT_SITE', '/');
        define('SITE_ID_CURRENT_SITE', 1);
        define('BLOG_ID_CURRENT_SITE', 1);
        if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO']==='https') \$_SERVER['HTTPS']='on';
        if (isset(\$_SERVER['HTTP_X_FORWARDED_HOST'])) \$_SERVER['HTTP_HOST']=\$_SERVER['HTTP_X_FORWARDED_HOST'];
    volumes:
      - /opt/wpms/html:/var/www/html
    depends_on: [db]
    networks: [proxy]
    expose: ["80"]
networks: { proxy: { external: true } }
YML

  # Portainer
  cat >/opt/portainer/docker-compose.yml <<'YML'
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/portainer/data:/data
    networks: [proxy]
    expose: ["9000"]
networks: { proxy: { external: true } }
YML

  # noVNC
  cat >/opt/vnc/docker-compose.yml <<YML
services:
  desk:
    image: dorowu/ubuntu-desktop-lxde-vnc
    restart: unless-stopped
    environment:
      - TZ=${TZ}
      - VNC_PASSWORD=${VNC_PASS}
    networks: [proxy]
    expose: ["80"]
networks: { proxy: { external: true } }
YML
}

run_stacks(){
  log "启动容器栈"
  docker compose -f /opt/npm/docker-compose.yml up -d
  docker compose -f /opt/nextcloud/docker-compose.yml up -d
  docker compose -f /opt/onlyoffice/docker-compose.yml up -d
  docker compose -f /opt/wordpress/docker-compose.yml up -d
  docker compose -f /opt/wpms/docker-compose.yml up -d
  docker compose -f /opt/portainer/docker-compose.yml up -d
  docker compose -f /opt/vnc/docker-compose.yml up -d
}

sftp_setup(){
  log "创建 SFTP(chroot) 账户"
  getent group sftponly >/dev/null || groupadd sftponly
  for u in "${!SFTP_PW[@]}"; do
    id "$u" >/dev/null 2>&1 || useradd -m -g sftponly -s /usr/sbin/nologin "$u"
    echo "${u}:${SFTP_PW[$u]}" | chpasswd
    mkdir -p /data/sftp/$u/upload
    chown -R root:sftponly /data/sftp/$u
    chmod 755 /data/sftp/$u
    chown -R $u:sftponly /data/sftp/$u/upload
  done
  if ! grep -q "Match Group sftponly" /etc/ssh/sshd_config; then
cat >>/etc/ssh/sshd_config <<'SSHD'
Match Group sftponly
  ChrootDirectory /data/sftp/%u
  ForceCommand internal-sftp
  X11Forwarding no
  AllowTcpForwarding no
SSHD
  fi
  systemctl restart ssh || systemctl restart sshd || true
}

wait_npm_ready(){
  log "等待 NPM :81 就绪"
  for _ in {1..60}; do
    curl -sSf http://127.0.0.1:81 >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

npm_auto(){
  log "尝试用 NPM API 自动创建全部 Proxy Host + SSL"
  wait_npm_ready || { echo "NPM 未就绪，跳过自动配置"; return 1; }

  TOKEN=$(curl -sS -X POST http://127.0.0.1:81/api/tokens \
    -H 'Content-Type: application/json' \
    -d '{"identity":"admin@example.com","secret":"changeme"}' | jq -r '.token // empty') || true
  [ -n "${TOKEN:-}" ] || { echo "NPM API 登录失败（版本可能不同），转为手动清单"; return 1; }

  # 改管理员邮箱
  curl -sS -X PATCH http://127.0.0.1:81/api/users/1 \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"email":"'"$EMAIL_ACME"'"}' >/dev/null || true

  create_host(){
    local DOMAIN="$1" TARGET="$2" EMAIL="$3" SCHEME="http" PORT="80"
    # 允许 TARGET 形如 127.0.0.1:81，则拆端口
    if [[ "$TARGET" == *:* ]]; then
      SCHEME="http"; PORT="${TARGET##*:}"; TARGET="${TARGET%%:*}"
    fi
    curl -sS -X POST http://127.0.0.1:81/api/nginx/proxy-hosts \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' \
      -d '{
        "domain_names":["'"$DOMAIN"'"],
        "forward_scheme":"'"$SCHEME"'",
        "forward_host":"'"$TARGET"'",
        "forward_port":'"$PORT"',
        "allow_websocket_upgrade":true,
        "block_exploits":true,
        "caching_enabled":true,
        "ssl_forced":true,
        "http2_support":true,
        "hsts_enabled":true,
        "letsencrypt_agree": true,
        "letsencrypt_email": "'"$EMAIL"'"
      }' >/dev/null
  }

  # 现有服务
  create_host "$DOM_NPM"        "127.0.0.1:81"            "$EMAIL_ACME"
  create_host "$DOM_NC"         "nextcloud-web"           "$EMAIL_ACME"
  create_host "$DOM_DOC"        "onlyoffice-doc"          "$EMAIL_ACME"
  create_host "$DOM_COCKPIT"    "172.17.0.1:9090"         "$EMAIL_ACME"
  create_host "$DOM_WP"         "wordpress-wp"            "$EMAIL_ACME"
  create_host "$DOM_PORTAINER"  "portainer-portainer:9000" "$EMAIL_ACME"
  create_host "$DOM_VNC"        "vnc-desk"                "$EMAIL_ACME"
  create_host "$DOM_AAPANEL"    "127.0.0.1:${AAPANEL_PORT}" "$EMAIL_ACME"

  # Multisite 主站 + 两个独立域
  create_host "$DOM_ADMIN"      "wpms-wpms"               "$EMAIL_ACME"
  for d in "${DOM_SITES[@]}"; do create_host "$d" "wpms-wpms" "$EMAIL_ACME"; done

  echo "NPM API 创建完成（证书签发可能需 1~2 分钟）"
  return 0
}

print_manual(){
  log "NPM 手动添加清单（若 API 失败时使用）"
  cat <<MAN

登录：http://${IPV4_PUBLIC}:81
每条 Proxy Host 勾选：Force SSL / HTTP/2 / HSTS / Cache Assets / Block Common Exploits
证书：Let's Encrypt（${EMAIL_ACME}）

1) ${DOM_NPM}        -> http://127.0.0.1:81
2) ${DOM_NC}         -> http://nextcloud-web:8080
3) ${DOM_DOC}        -> http://onlyoffice-doc:80
4) ${DOM_COCKPIT}    -> http://172.17.0.1:9090
5) ${DOM_WP}         -> http://wordpress-wp:80
6) ${DOM_PORTAINER}  -> http://portainer-portainer:9000
7) ${DOM_VNC}        -> http://vnc-desk:80
8) ${DOM_AAPANEL}    -> http://127.0.0.1:${AAPANEL_PORT}
9) ${DOM_ADMIN}      -> http://wpms-wpms:80
10) ezglinns.com     -> http://wpms-wpms:80
11) gsliberty.com    -> http://wpms-wpms:80

DNS：以上域名的 A 记录都需指向 ${IPV4_PUBLIC}
MAN
}

summary(){
  log "部署完成概要"
  cat <<SUM
IP: ${IPV4_PUBLIC}
主域名：${DOM_MAIN}

统一后台（WP Multisite）：
  https://${DOM_ADMIN} → 初装后进入 Network Admin → Sites → Add New 添加/管理站点
 （已预置 ezglinns.com / gsliberty.com 的反代；在后台添加站点即可生效）

其它服务：
  NPM：       https://${DOM_NPM}
  Nextcloud： https://${DOM_NC}
  OnlyOffice：https://${DOM_DOC}
  Cockpit：   https://${DOM_COCKPIT}
  WordPress： https://${DOM_WP}
  Portainer： https://${DOM_PORTAINER}
  noVNC：     https://${DOM_VNC}   （VNC 密码：${VNC_PASS}）
  aaPanel：   https://${DOM_AAPANEL}（你安装并监听 ${AAPANEL_PORT} 后生效）

SFTP：
  admin / 862447
  staff / 862446
  support / 862445
  billing / 862444
  地址：sftp://${DOM_MAIN} 或 sftp://${IPV4_PUBLIC}
  目录：/data/sftp/<用户>/upload
SUM
}

main(){
  need_root
  apt_setup
  docker_setup
  ufw_fail2ban_setup
  layout_dirs
  compose_files
  run_stacks
  sftp_setup
  if ! npm_auto; then
    print_manual
  fi
  summary
}
main "$@"
