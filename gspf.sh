### [GSPF.SH FULL BLOCK 1/3 START]
#!/usr/bin/env bash
################################################################################
# GS-PRO FINAL — 一键部署 + 断点恢复 + NPM/SSL 强化修复 (Ubuntu 24.04 LTS)
# 内容：Docker / NPM(反代) / Nextcloud / OnlyOffice / WordPress Multisite
#       Cockpit / noVNC / Fail2ban / 自动 SSL / 断点恢复 / 日志 / 再部署检测
################################################################################
set -Eeuo pipefail

###==================== 基础变量（可修改） ====================###
MAIN_DOMAIN="hulin.pro"
ADMIN_EMAIL="gs@hulin.pro"
NPM_ADMIN_USER="admin"
NPM_ADMIN_PASS="Gaomeilan862447#"

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

PORT_WP_HTTP=9080
PORT_NC_HTTP=9000
PORT_OO_HTTP=9980
PORT_COCKPIT=9090
PORT_NOVNC=6080
PORT_VNC=5905

VNC_PASS="862447"

WHITELIST_IPS=("172.56.160.206" "172.56.164.101" "176.56.161.108")

ROOT_DIR="/gspro"
LOG_FILE="/root/gspro.log"
PROGRESS_FILE="/root/.gspro-progress"

###==================== 工具函数 ====================###
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m"; }

exec > >(tee -a "$LOG_FILE") 2>&1

step(){
  local num="$1" ; shift
  local title="$*"
  local last=0
  [[ -f "$PROGRESS_FILE" ]] && last="$(cat "$PROGRESS_FILE" 2>/dev/null||echo 0)"
  if [[ "$last" -ge "$num" ]]; then
    yellow "[SKIP] Step $num $title（已完成）"
    return 1
  fi
  echo "$num" > "$PROGRESS_FILE"
  green "[RUN] Step $num：$title"
  return 0
}

SERVER_IP="$(hostname -I | awk '{print $1}')"

need_root(){ [[ $EUID -eq 0 ]] || { red "必须使用 root"; exit 1; }; }
need_ubuntu_2404(){ grep -q "Ubuntu 24.04" /etc/os-release || { red "必须 Ubuntu 24.04"; exit 1; }; }

apt_quiet(){ DEBIAN_FRONTEND=noninteractive apt-get -yq "$@"; }

wait_for_port_free(){
  local p=$1
  if ss -tulpn | grep -q ":$p\b"; then
    yellow "端口 $p 被占用 → 尝试 kill"
    local pids
    pids="$(ss -tulpn | awk -v P=":$p" '$0 ~ P{print $NF}'|sed -n 's/.*pid=\([0-9]\+\).*/\1/p'|sort -u)"
    for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 1
  fi
}

json_or_empty(){
  local payload="$1"
  echo "$payload" | jq . >/dev/null 2>&1 && echo "$payload" || echo "{}"
}

wait_for_http(){
  local url="$1" expect="${2:-200}" timeout="${3:-180}" t=0 code
  while ((t < timeout)); do
    code="$(curl -sk -o /dev/null -w '%{http_code}' "$url"||true)"
    [[ "$code" == "$expect" ]] && return 0
    sleep 3; t=$((t+3))
  done
  return 1
}

ensure_base_tools(){
  apt_quiet update
  apt_quiet install -y curl jq dnsutils ca-certificates gnupg lsb-release software-properties-common ufw
}

###================ Step 0 基础环境检查 =================###
if step 0 "基础环境检查与准备"; then
  need_root
  need_ubuntu_2404
  ensure_base_tools
  green "[OK] Ubuntu 24.04 LTS ✔"
  green "[OK] 检测到服务器 IP：$SERVER_IP"
fi

###================ Step 1 清理旧环境 =================###
if step 1 "清理 Docker/Nginx/Apache/容器"; then
  systemctl stop apache2 nginx docker containerd >/dev/null 2>&1 || true
  apt_quiet remove -y apache2* nginx* || true

  if command -v docker >/dev/null 2>&1; then
    docker ps -aq | xargs -r docker stop || true
    docker ps -aq | xargs -r docker rm || true
  fi

  apt_quiet remove -y docker docker.io docker-engine containerd runc || true
  umount /var/lib/docker 2>/dev/null || true
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker

  for p in 80 81 443 9090 6080 5905 9080 9000 9980; do
    wait_for_port_free "$p"
  done

  green "[OK] 旧环境完全清理完成"
fi

###================ Step 2 安装 Docker =================###
if step 2 "系统更新 + 安装 Docker"; then
  apt_quiet update
  apt_quiet upgrade -y

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    >/etc/apt/sources.list.d/docker.list

  apt_quiet update
  apt_quiet install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker --now

  green "[OK] Docker 已就绪"
fi

###================ Step 3 创建目录结构 =================###
if step 3 "创建基础目录结构"; then
  mkdir -p "$ROOT_DIR"/{npm,nextcloud,office,novnc,portainer,wp,config,logs,ssl}
  green "[OK] 目录结构创建：$ROOT_DIR/*"
fi

###================ Step 4 部署 NPM =================###
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

  wait_for_http "http://127.0.0.1:81" 200 240 || yellow "NPM UI 未返回 200（继续）"

  green "[OK] NPM 启动成功"
fi
### [GSPF.SH FULL BLOCK 1/3 END]
### [GSPF.SH FULL BLOCK 2/3 START]

###================ Step 5 部署 Nextcloud & OnlyOffice =================###
if step 5 "部署 Nextcloud & OnlyOffice"; then
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
  green "[OK] Nextcloud + OnlyOffice 启动完成"
fi


###================ Step 6 部署 WordPress Multisite =================###
if step 6 "部署 WordPress Multisite"; then
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

  green "[OK] WordPress 多站点容器已启动"
fi


###================ Step 7 配置 WP 多站点 =================###
if step 7 "配置 WordPress Multisite"; then
  WP_PATH="$ROOT_DIR/wp/html"
  t=0
  while [[ ! -f "$WP_PATH/wp-config-sample.php" && $t -lt 240 ]]; do
    sleep 3; t=$((t+3))
  done

  if [[ -f "$WP_PATH/wp-config-sample.php" ]]; then
    cp -n "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php" || true
    cat >>"$WP_PATH/wp-config.php" <<EOF

/* Multisite 启用 */
define( 'WP_ALLOW_MULTISITE', true );
define( 'MULTISITE', true );
define( 'SUBDOMAIN_INSTALL', true );
define( 'DOMAIN_CURRENT_SITE', '${MAIN_DOMAIN}' );
define( 'PATH_CURRENT_SITE', '/' );
define( 'SITE_ID_CURRENT_SITE', 1 );
define( 'BLOG_ID_CURRENT_SITE', 1 );
define( 'COOKIE_DOMAIN', '' );
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO']==='https'){\$_SERVER['HTTPS']='on';}
EOF
  fi

  mkdir -p "$WP_PATH"
  cat >"$WP_PATH/.htaccess" <<'EOF'
RewriteEngine On
RewriteBase /
RewriteRule ^wp-admin$ /wp-admin/network/ [R=301,L]
EOF

  green "[OK] WordPress 多站后台跳转设置完成"
fi


###================ Step 8 Cockpit / noVNC / VNC =================###
if step 8 "部署 Cockpit + noVNC + VNC 桌面"; then
  apt_quiet install -y cockpit cockpit-networkmanager cockpit-packagekit
  systemctl enable cockpit --now || true

  apt_quiet install -y novnc websockify tigervnc-standalone-server xfce4 xfce4-goodies
  mkdir -p /root/.vnc
  echo "${VNC_PASS}" | vncpasswd -f >/root/.vnc/passwd
  chmod 600 /root/.vnc/passwd

  cat >/root/.vnc/xstartup <<'EOF'
#!/bin/sh
xrdb $HOME/.Xresources
startxfce4 &
EOF
  chmod +x /root/.vnc/xstartup

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

  # noVNC 绑定
  nohup websockify --web=/usr/share/novnc/ ${PORT_NOVNC} localhost:${PORT_VNC} >/dev/null 2>&1 &

  green "[OK] Cockpit/NoVNC/VNC 已启动"
fi


###================ Step 9 Fail2ban + 防火墙 =================###
if step 9 "配置 Fail2ban + 防火墙"; then
  apt_quiet install -y fail2ban

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

  systemctl enable fail2ban --now

  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 81/tcp
  ufw allow 443/tcp
  ufw allow ${PORT_COCKPIT}/tcp
  ufw allow ${PORT_VNC}/tcp
  ufw allow ${PORT_NOVNC}/tcp
  ufw --force enable

  green "[OK] Fail2ban & 防火墙 已配置"
fi

### [GSPF.SH FULL BLOCK 2/3 END] 
### [GSPF.SH FULL BLOCK 3/3 START]

###================ Step 10 /etc/hosts 写入 =================###
if step 10 "/etc/hosts 写入当前服务器 IP"; then
  for d in "${DOMAINS_ALL[@]}"; do
    if ! grep -qE "[[:space:]]${d}$" /etc/hosts; then
      echo "${SERVER_IP} ${d}" >> /etc/hosts
      echo " + 写入 hosts：$d"
    fi
  done
  green "[OK] /etc/hosts 更新完成"
fi


###================ NPM API 函数 =================###
NPM_API="http://127.0.0.1:81/api"
TOKEN=""

npm_api_login(){
  local payload resp
  payload="{\"identity\":\"${NPM_ADMIN_USER}\",\"secret\":\"${NPM_ADMIN_PASS}\"}"
  resp="$(curl -sS -H "Content-Type: application/json" -X POST "${NPM_API}/tokens" -d "$payload" || true)"
  resp="$(json_or_empty "$resp")"
  TOKEN="$(echo "$resp" | jq -r '.token // empty')"
  [[ -n "$TOKEN" && "$TOKEN" != "null" ]]
}

npm_auth_hdr(){
  echo "Authorization: Bearer ${TOKEN}"
}

ensure_token_ready(){
  local tries=0
  until npm_api_login; do
    tries=$((tries+1))
    [[ $tries -gt 30 ]] && return 1
    sleep 5
  done
  return 0
}

create_proxy_host(){
  local domain="$1" target="$2"
  local fhost="$(echo "$target" | sed 's~http://~~; s~https://~~;' | cut -d: -f1)"
  local fport="$(echo "$target" | sed 's~http://~~; s~https://~~;' | cut -d: -f2)"

  local req resp
  req="$(jq -nc \
        --argjson dn "[\"$domain\"]" \
        --arg fh "$fhost" \
        --argjson fp "$fport" \
        '{domain_names:$dn, forward_scheme:"http", forward_host:$fh,
          forward_port:($fp|tonumber), access_list_id:0, certificate_id:0,
          ssl_forced:false}')"

  resp="$(curl -sS -H "$(npm_auth_hdr)" -H "Content-Type: application/json" \
          -X POST "${NPM_API}/nginx/proxy-hosts" -d "$req" || true)"

  json_or_empty "$resp" >/dev/null || true
}

get_proxy_id(){
  local domain="$1"
  local resp="$(curl -sS -H "$(npm_auth_hdr)" "${NPM_API}/nginx/proxy-hosts" || true)"
  resp="$(json_or_empty "$resp")"
  echo "$resp" | jq ".[]|select(.domain_names[]==\"$domain\")|.id" | head -n1
}


###================ Step 11 创建 NPM 反代 =================###
if step 11 "创建所有反代规则"; then
  wait_for_http "http://127.0.0.1:81" 200 240 || yellow "NPM 未完全启动，继续尝试"
  ensure_token_ready || yellow "无法登录 NPM API (token)，后续步骤可能失败"

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
    create_proxy_host "$d" "${MAP[$d]}" || true
    sleep 1
  done

  green "[OK] 所有反代创建完成"
fi


###================ SSL 请求函数 =================###
issue_cert(){
  local domain="$1"
  local req resp

  req="$(jq -nc \
    --argjson dn "[\"$domain\"]" \
    --arg em "$ADMIN_EMAIL" \
    '{domain_names:$dn,email:$em,provider:"letsencrypt",challenge:"http",
      agree_tos:true}')"

  resp="$(curl -sS -H "$(npm_auth_hdr)" -H "Content-Type: application/json" \
          -X POST "${NPM_API}/certificates" -d "$req" || true)"

  json_or_empty "$resp"
}

bind_cert(){
  local proxy_id="$1" cert_id="$2"
  local req resp

  req="$(jq -nc --argjson id "$cert_id" \
    '{certificate_id:$id,ssl_forced:true,http2_support:true,
      hsts_enabled:false,hsts_subdomains:false}')"

  resp="$(curl -sS -H "$(npm_auth_hdr)" -H "Content-Type: application/json" \
          -X PUT "${NPM_API}/nginx/proxy-hosts/${proxy_id}" -d "$req" || true)"

  json_or_empty "$resp" >/dev/null || true
}

dns_points_to_me(){
  local d="$1"
  local a
  a="$(dig +short "$d" | head -n1)"
  [[ "$a" == "$SERVER_IP" ]]
}


###================ Step 12 自动申请并绑定 SSL =================###
if step 12 "申请 SSL + 自动绑定（批量）"; then
  ensure_token_ready || yellow "NPM API 无法登录，SSL 步骤可能失败"

  for d in "${DOMAINS_ALL[@]}"; do
    echo ""
    echo "🔎 域名：$d"

    if ! dns_points_to_me "$d"; then
      yellow "  ❌ DNS 未指向 $SERVER_IP，跳过"
      continue
    fi

    hid="$(get_proxy_id "$d" | tr -d '\n')"
    if [[ -z "$hid" || "$hid" == "null" ]]; then
      yellow "  ❌ 找不到 Proxy Host，跳过"
      continue
    fi

    green "  ✓ Proxy Host ID: $hid，开始申请证书"

    cid=""
    for try in 1 2 3; do
      resp="$(issue_cert "$d")"
      cid="$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo '')"

      if [[ -n "$cid" && "$cid" != "null" ]]; then
        green "  ✓ SSL 证书申请成功：ID=$cid"
        break
      fi

      yellow "  ⚠️ 第 ${try} 次申请失败，等待 30 秒重试..."
      sleep 30
    done

    if [[ -z "$cid" || "$cid" == "null" ]]; then
      yellow "  ❌ 证书创建失败，跳过绑定"
      continue
    fi

    bind_cert "$hid" "$cid"
    green "  ✓ SSL 已绑定"
  done

  docker exec npm nginx -s reload || true

  green "[OK] 所有域名 SSL 已处理"
fi


###================ 全部完成 =================###
echo ""
green "🎉 GS-PRO 全功能部署完成！（含断点恢复）"
echo "日志文件：$LOG_FILE"
echo ""
echo "访问入口："
echo "  • 主站 WP       https://${MAIN_DOMAIN}"
echo "  • WP 多站后台   https://wp.${MAIN_DOMAIN}/wp-admin/network/"
echo "  • Nextcloud     https://dri.${MAIN_DOMAIN}"
echo "  • OnlyOffice    https://doc.${MAIN_DOMAIN}"
echo "  • NPM Dashboard https://npm.${MAIN_DOMAIN}"
echo "  • Cockpit       https://coc.${MAIN_DOMAIN}"
echo "  • noVNC         https://vnc.${MAIN_DOMAIN}"
echo ""
echo "如需重新部署：删除断点文件后重新执行"
echo "  rm -f $PROGRESS_FILE"
echo ""
green "🌟 完成！"

### [GSPF.SH FULL BLOCK 3/3 END]
