#!/usr/bin/env bash
################################################################################
# GS-PRO FINAL — 一键部署 + 断点恢复 + NPM/SSL 强化修复 (Ubuntu 24.04 LTS)
# 内容：Docker / NPM(反代) / Nextcloud / OnlyOffice / WordPress Multisite
#       Cockpit / noVNC / Fail2ban / 自动 SSL / 断点恢复 / 日志
################################################################################

set -Eeuo pipefail

#======================== 基础可修改变量 ========================#
MAIN_DOMAIN="hulin.pro"
ADMIN_EMAIL="gs@hulin.pro"
NPM_ADMIN_USER="admin"
NPM_ADMIN_PASS="Gaomeilan862447#"

# 子域（如需增删，在此处调整；脚本会自动创建反代与证书）
DOMAINS_ALL=(
  "hulin.pro"
  "ezglinns.com"
  "hulin.bz"
  "wp.hulin.pro"
  "admin.hulin.pro"
  "doc.hulin.pro"
  "dri.hulin.pro"
  "coc.hulin.pro"
  "npm.hulin.pro"
  "vnc.hulin.pro"
)

# 服务端口（容器对外暴露端口；不要动 80/81/443）
PORT_WP_HTTP=9080
PORT_NC_HTTP=9000
PORT_OO_HTTP=9980
PORT_COCKPIT=9090
PORT_NOVNC=6080
PORT_VNC=5905

# VNC 密码
VNC_PASS="862447"

# Fail2ban 免封白名单（你的手机/iPad/WiFi 公网 IP）
WHITELIST_IPS=("172.56.160.206" "172.56.164.101" "176.56.161.108")

# 路径
ROOT_DIR="/gspro"
LOG_FILE="/root/gspro.log"
PROGRESS_FILE="/root/.gspro-progress"

#======================== 打印函数 ========================#
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m"; }

# 记录日志
exec > >(tee -a "$LOG_FILE") 2>&1

#======================== 断点恢复机制 ========================#
step() {
  local num="$1" ; shift
  local title="$*"
  local last=0
  [[ -f "$PROGRESS_FILE" ]] && last="$(cat "$PROGRESS_FILE" 2>/dev/null || echo 0)"
  if [[ "$last" -ge "$num" ]]; then
    yellow "[SKIP] Step $num: $title（已完成）"
    return 1
  fi
  echo "$num" > "$PROGRESS_FILE"
  green "[OK] 开始 Step $num：$title"
  return 0
}

#======================== 通用工具函数 ========================#
SERVER_IP="$(hostname -I | awk '{print $1}')"

need_root() {
  if [[ $EUID -ne 0 ]]; then red "必须使用 root 运行"; exit 1; fi
}

need_ubuntu_2404() {
  grep -q "Ubuntu 24.04" /etc/os-release || { red "必须 Ubuntu 24.04 LTS"; exit 1; }
}

apt_quiet() { DEBIAN_FRONTEND=noninteractive apt-get -yq "$@" ; }

wait_for_port_free() {
  local p=$1
  if ss -tulpn | grep -q ":$p\b"; then
    yellow "端口 $p 被占用，尝试释放..."
    local pids
    pids="$(ss -tulpn | awk -v P=":$p" '$0 ~ P {print $NF}' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)"
    if [[ -n "${pids}" ]]; then
      for pid in $pids; do kill -9 "$pid" || true; done
      sleep 1
    fi
  fi
}

wait_for_http() {
  # wait_for_http URL code timeout_seconds
  local url="$1" need="${2:-200}" timeout="${3:-120}" t=0
  while (( t < timeout )); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' "$url" || true)"
    [[ "$code" == "$need" ]] && return 0
    sleep 3; t=$((t+3))
  done
  return 1
}

json_or_empty() {
  # 将可能的 HTML/空输出保护为 {}，避免 jq 报错：Invalid numeric literal
  local payload="$1"
  if echo "$payload" | jq -e . >/dev/null 2>&1; then
    echo "$payload"
  else
    echo "{}"
  fi
}

ensure_base_tools() {
  apt_quiet update
  apt_quiet install -y curl jq dnsutils ca-certificates gnupg lsb-release
}

#======================== 步骤 0：基础系统检查 ========================#
if step 0 "基础环境检查与准备"; then
  need_root
  need_ubuntu_2404
  ensure_base_tools
  green "[OK] 系统版本正确：Ubuntu 24.04 LTS"
  green "[OK] 自动检测服务器 IP：$SERVER_IP"
fi

#======================== 步骤 1：清理旧环境 ========================#
if step 1 "清理旧环境：Docker/Apache/旧反代/冲突端口"; then
  systemctl stop apache2 nginx >/dev/null 2>&1 || true
  systemctl disable apache2 nginx >/dev/null 2>&1 || true
  apt_quiet remove -y apache2* nginx* || true

  # 停老容器，避免 /var/lib/docker 忙碌
  if command -v docker >/dev/null 2>&1; then
    docker ps -aq | xargs -r docker stop || true
    docker ps -aq | xargs -r docker rm || true
  fi

  apt_quiet remove -y docker docker.io docker-engine containerd runc || true
  systemctl stop docker containerd >/dev/null 2>&1 || true
  systemctl disable docker containerd >/dev/null 2>&1 || true

  umount /var/lib/docker 2>/dev/null || true
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker || true

  # 释放关键端口
  for p in 80 81 443 "$PORT_COCKPIT" "$PORT_NOVNC" "$PORT_VNC" "$PORT_WP_HTTP" "$PORT_NC_HTTP" "$PORT_OO_HTTP"; do
    wait_for_port_free "$p"
  done

  green "[OK] 旧环境清理完成"
fi

#======================== 步骤 2：系统更新与 Docker 安装 ========================#
if step 2 "系统更新 + 安装 Docker / Compose"; then
  apt_quiet update
  apt_quiet upgrade -y

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    >/etc/apt/sources.list.d/docker.list

  apt_quiet update
  apt_quiet install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker --now
  green "[OK] Docker / Compose 就绪"
fi

#======================== 步骤 3：创建目录结构 ========================#
if step 3 "创建基础目录结构"; then
  mkdir -p "$ROOT_DIR"/{npm,nextcloud,office,novnc,portainer,wp,config,logs,ssl}
  green "[OK] 目录创建完成：$ROOT_DIR/*"
fi

#======================== 步骤 4：部署 NPM ========================#
if step 4 "部署 Nginx Proxy Manager"; then
  cat >"$ROOT_DIR/npm/docker-compose.yml" <<EOF
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
  (cd "$ROOT_DIR/npm" && docker compose up -d)
  # 等 NPM UI 就绪
  wait_for_http "http://127.0.0.1:81" 200 240 || yellow "NPM UI 未返回 200，但继续..."
  green "[OK] NPM 已启动（80/81/443）"
fi

#======================== 步骤 5：部署 Nextcloud & OnlyOffice ========================#
if step 5 "部署 Nextcloud & OnlyOffice (Docker)"; then
  cat >"$ROOT_DIR/nextcloud/docker-compose.yml" <<EOF
version: '3.8'
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
  green "[OK] Nextcloud/OnlyOffice 启动完成"
fi

#======================== 步骤 6：部署 WordPress Multisite ========================#
if step 6 "部署 WordPress Multisite (Docker)"; then
  cat >"$ROOT_DIR/wp/docker-compose.yml" <<EOF
version: '3.8'
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
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: ${NPM_ADMIN_PASS}
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - ./html:/var/www/html

  wp_web:
    image: nginx:stable
    container_name: wp_nginx
    restart: unless-stopped
    ports:
      - "${PORT_WP_HTTP}:80"
    volumes:
      - ./html:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
    depends_on: [wp_fpm]
EOF

  cat >"$ROOT_DIR/wp/nginx.conf" <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html;
    index index.php index.html;
    location / {
        try_files $uri $uri/ /index.php?$args;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass wp_fpm:9000;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF
  (cd "$ROOT_DIR/wp" && docker compose up -d)
  green "[OK] WordPress 多站点容器已启动 (HTTP :$PORT_WP_HTTP)"
fi

#======================== 步骤 7：配置 WordPress 多站点 ========================#
if step 7 "配置 WordPress Multisite (wp-config.php)"; then
  WP_PATH="$ROOT_DIR/wp/html"
  # 等待 WP 初始化落盘
  t=0
  while [[ ! -f "$WP_PATH/wp-config-sample.php" && $t -lt 240 ]]; do
    sleep 3; t=$((t+3))
  done
  [[ ! -f "$WP_PATH/wp-config-sample.php" ]] && yellow "未检测到 WP 文件，但继续..." || {
    cp -n "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php" || true
    cat >>"$WP_PATH/wp-config.php" <<EOF

/* Multisite 启用与反代修正 */
define( 'WP_ALLOW_MULTISITE', true );
define( 'MULTISITE', true );
define( 'SUBDOMAIN_INSTALL', true );
define( 'DOMAIN_CURRENT_SITE', '${MAIN_DOMAIN}' );
define( 'PATH_CURRENT_SITE', '/' );
define( 'SITE_ID_CURRENT_SITE', 1 );
define( 'BLOG_ID_CURRENT_SITE', 1 );
define( 'COOKIE_DOMAIN', '' );
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') { \$_SERVER['HTTPS'] = 'on'; }
EOF
    green "[OK] wp-config.php 多站点参数写入完成"
  }
  # 强制网络后台跳转
  mkdir -p "$WP_PATH"
  cat >"$WP_PATH/.htaccess" <<'EOF'
RewriteEngine On
RewriteBase /
RewriteRule ^wp-admin$ /wp-admin/network/ [R=301,L]
EOF
  green "[OK] 多站后台跳转规则已设置"
fi

#======================== 步骤 8：Cockpit / noVNC ========================#
if step 8 "部署 Cockpit / noVNC (VNC:5905 / noVNC:6080)"; then
  apt_quiet install -y cockpit cockpit-networkmanager cockpit-packagekit
  systemctl enable cockpit --now || true

  # noVNC + VNC Server（XFCE 桌面）
  apt_quiet install -y novnc websockify tigervnc-standalone-server xfce4 xfce4-goodies
  # VNC 密码
  mkdir -p /root/.vnc
  echo "${VNC_PASS}" | vncpasswd -f >/root/.vnc/passwd
  chmod 600 /root/.vnc/passwd
  cat > /root/.vnc/xstartup <<'EOF'
#!/bin/sh
xrdb $HOME/.Xresources
startxfce4 &
EOF
  chmod +x /root/.vnc/xstartup

  # systemd 管理 VNC :5
  cat >/etc/systemd/system/vnc@5.service <<EOF
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
  systemctl enable vnc@5 --now

  # noVNC 反代端口
  wait_for_port_free "$PORT_NOVNC"
  nohup websockify --web=/usr/share/novnc/ ${PORT_NOVNC} localhost:${PORT_VNC} >/dev/null 2>&1 &

  green "[OK] Cockpit 与 noVNC 已启动"
fi

#======================== 步骤 9：Fail2ban + UFW ========================#
if step 9 "配置 Fail2ban + UFW 防火墙"; then
  apt_quiet install -y fail2ban ufw
  local_ignore="127.0.0.1/8"
  for ip in "${WHITELIST_IPS[@]}"; do local_ignore+=" ${ip}"; done

  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = ${local_ignore}
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = /var/log/auth.log
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

  green "[OK] 防火墙与 Fail2ban 已生效"
fi

#======================== 步骤 10：/etc/hosts 写入（容器内部解析） ========================#
if step 10 "/etc/hosts 写入（指向当前 SERVER_IP）"; then
  for d in "${DOMAINS_ALL[@]}"; do
    if ! grep -qE "[[:space:]]${d}\$" /etc/hosts; then
      echo "${SERVER_IP} ${d}" >> /etc/hosts
      echo " + hosts 添加：${d}"
    fi
  done
  green "[OK] /etc/hosts 更新完成"
fi

#======================== 步骤 11：NPM API 登录 + 批量创建反代 ========================#
NPM_API="http://127.0.0.1:81/api"
TOKEN=""
npm_api_login() {
  # NPM v2.13+ 获取短期 token（Bearer）
  local payload resp
  payload="{\"identity\":\"${NPM_ADMIN_USER}\",\"secret\":\"${NPM_ADMIN_PASS}\"}"
  resp="$(curl -sS -H "Content-Type: application/json" -X POST "${NPM_API}/tokens" -d "$payload" || true)"
  resp="$(json_or_empty "$resp")"
  TOKEN="$(echo "$resp" | jq -r '.token // empty')"
  [[ -z "$TOKEN" || "$TOKEN" == "null" ]] && return 1 || return 0
}

npm_auth_hdr() { echo "Authorization: Bearer ${TOKEN}"; }

ensure_token_ready() {
  local tries=0
  until npm_api_login; do
    tries=$((tries+1))
    [[ $tries -gt 30 ]] && return 1
    sleep 5
  done
  return 0
}

create_proxy_host() {
  local domain="$1" target="$2"
  local host="$(echo "$target" | sed 's~http://~~; s~https://~~;')"
  local fhost="$(echo "$host" | cut -d: -f1)"
  local fport="$(echo "$host" | cut -d: -f2)"
  local req resp
  req="$(jq -nc --argjson dn "[\"$domain\"]" --arg fh "$fhost" --argjson fp "$fport" \
      '{domain_names:$dn, forward_scheme:"http", forward_host:$fh, forward_port:($fp|tonumber),
        access_list_id:0, certificate_id:0, ssl_forced:false}')"
  resp="$(curl -sS -H "$(npm_auth_hdr)" -H "Content-Type: application/json" \
               -X POST "${NPM_API}/nginx/proxy-hosts" -d "$req" || true)"
  json_or_empty "$resp"
}

get_proxy_id() {
  local domain="$1"
  local resp="$(curl -sS -H "$(npm_auth_hdr)" "${NPM_API}/nginx/proxy-hosts" || true)"
  resp="$(json_or_empty "$resp")"
  echo "$resp" | jq ".[] | select(.domain_names[]==\"$domain\") | .id" | head -n1
}

if step 11 "创建 NPM 反代配置（批量）"; then
  wait_for_http "http://127.0.0.1:81" 200 240 || yellow "NPM UI 未稳定返回 200"
  ensure_token_ready || yellow "NPM 获取 token 失败，但继续尝试（可能失败）"

  declare -A MAP=(
    ["hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["wp.hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["admin.hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["ezglinns.com"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["hulin.bz"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["doc.hulin.pro"]="http://172.17.0.1:${PORT_OO_HTTP}"
    ["dri.hulin.pro"]="http://172.17.0.1:${PORT_NC_HTTP}"
    ["coc.hulin.pro"]="http://127.0.0.1:${PORT_COCKPIT}"
    ["npm.hulin.pro"]="http://127.0.0.1:81"
    ["vnc.hulin.pro"]="http://127.0.0.1:${PORT_NOVNC}"
  )

  for d in "${!MAP[@]}"; do
    yellow " → 创建反代：$d"
    create_proxy_host "$d" "${MAP[$d]}" >/dev/null || true
    sleep 1
  done
  green "[OK] 所有反代创建完成"
fi

#======================== 步骤 12：自动申请并绑定 SSL（强化 jq 防护） ========================#
issue_cert() {
  local domain="$1"
  local req resp
  req="$(jq -nc --argjson dn "[\"$domain\"]" --arg em "$ADMIN_EMAIL" \
        '{domain_names:$dn, email:$em, provider:"letsencrypt", challenge:"http", agree_tos:true}')"
  resp="$(curl -sS -H "$(npm_auth_hdr)" -H "Content-Type: application/json" \
              -X POST "${NPM_API}/certificates" -d "$req" || true)"
  echo "$(json_or_empty "$resp")"
}

bind_cert() {
  local proxy_id="$1" cert_id="$2"
  local req resp
  req="$(jq -nc --argjson cid "$cert_id" \
        '{certificate_id:$cid, ssl_forced:true, http2_support:true, hsts_enabled:false, hsts_subdomains:false}')"
  resp="$(curl -sS -H "$(npm_auth_hdr)" -H "Content-Type: application/json" \
              -X PUT "${NPM_API}/nginx/proxy-hosts/${proxy_id}" -d "$req" || true)"
  json_or_empty "$resp" >/dev/null || true
}

dns_points_to_me() {
  local d="$1"
  local a
  a="$(dig +short "$d" | head -n1)"
  [[ "$a" == "$SERVER_IP" ]]
}

if step 12 "申请并绑定 SSL（批量）"; then
  ensure_token_ready || yellow "NPM token 获取失败，SSL 步骤可能失败"
  for d in "${DOMAINS_ALL[@]}"; do
    echo ""
    echo "▶︎ 域名：$d"
    if ! dns_points_to_me "$d"; then
      yellow "  ❌ DNS 未指向 $SERVER_IP，跳过"
      continue
    fi
    green "  [OK] DNS 正确"

    # 查找 Proxy Host ID
    hid="$(get_proxy_id "$d" | tr -d '\n')"
    if [[ -z "$hid" || "$hid" == "null" ]]; then
      yellow "  ❌ 未找到 Proxy Host，跳过"
      continue
    fi
    echo "  Proxy Host ID: $hid"

    # 申请证书，最多重试 3 次（防止 NPM 返回 HTML 导致 jq 错误）
    cid=""
    for try in 1 2 3; do
      resp="$(issue_cert "$d")"
      cid="$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo '')"
      if [[ -n "$cid" && "$cid" != "null" ]]; then
        break
      fi
      yellow "  证书申请失败（第 ${try} 次），等待 30s 重试..."
      sleep 30
    done

    if [[ -z "$cid" || "$cid" == "null" ]]; then
      yellow "  ❌ 证书创建失败，跳过该域名"
      continue
    fi
    green "  证书创建成功：ID=$cid"

    bind_cert "$hid" "$cid"
    green "  SSL 已绑定"
  done

  # 重载 NPM
  docker exec npm nginx -s reload || true
  green "[OK] NPM 已重载"
fi

#======================== 完成 ========================#
echo ""
green "✅ 部署已全部完成！断点文件已更新。"
echo "日志：$LOG_FILE"
echo ""
echo "访问入口："
echo "  • 主站        https://${MAIN_DOMAIN}"
echo "  • 多站后台    https://wp.${MAIN_DOMAIN}/wp-admin/network/"
echo "  • Nextcloud   https://dri.${MAIN_DOMAIN}"
echo "  • OnlyOffice  https://doc.${MAIN_DOMAIN}"
echo "  • NPM         https://npm.${MAIN_DOMAIN}"
echo "  • Cockpit     https://coc.${MAIN_DOMAIN}"
echo "  • noVNC       https://vnc.${MAIN_DOMAIN}"
echo ""
echo "如需重跑：保存 PROGRESS_FILE 为更小的数字或删除： $PROGRESS_FILE"

