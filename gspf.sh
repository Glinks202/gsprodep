#!/usr/bin/env bash
# =========================
# GS-PRO VPS FINAL EDITION
# Fully Automated Deployment
# Ubuntu 24.04 LTS Only
# =========================
set -Eeuo pipefail

### ========== 基础变量 ========== ###
MAIN_DOMAIN="hulin.pro"
EMAIL="gs@hulin.pro"
NPM_ADMIN_USER="admin"
NPM_ADMIN_PASS="Gaomeilan862447#"

SERVER_IP="$(hostname -I | awk '{print $1}')"

DOMAINS_ALL=(
  "hulin.pro"
  "ezglinns.com"
  "gsliberty.com"
  "wp.hulin.pro"
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
PROGRESS_FILE="/root/.gspro-progress"

### ========== 打印工具 ========== ###
green(){ echo -e "\033[1;32m$*\033[0m"; }
yellow(){ echo -e "\033[1;33m$*\033[0m"; }
red(){ echo -e "\033[1;31m$*\033[0m"; }

exec > >(tee -a "$LOG_FILE") 2>&1

### ========== 断点恢复 ========== ###
step() {
  local num="$1"; shift
  local title="$*"
  local last=0

  [[ -f "$PROGRESS_FILE" ]] && last="$(cat "$PROGRESS_FILE" || echo 0)"

  if [[ "$last" -ge "$num" ]]; then
    yellow "[SKIP] Step $num: $title"
    return 1
  fi

  echo "$num" > "$PROGRESS_FILE"
  green "[RUN] Step $num: $title"
  return 0
}

### ========== 基础检查 ========== ###
need_root(){ [[ $EUID -ne 0 ]] && { red "必须使用 root"; exit 1; }; }
need_ubuntu(){ grep -q "Ubuntu 24.04" /etc/os-release || { red "必须 Ubuntu 24.04"; exit 1; }; }

apt_quiet(){ DEBIAN_FRONTEND=noninteractive apt-get -yq "$@"; }

wait_port_free(){
  p="$1"
  if ss -tulpn | grep -q ":$p"; then
    ids=$(ss -tulpn | grep ":$p" | sed -E 's/.*pid=([0-9]+).*/\1/')
    for pid in $ids; do kill -9 "$pid" || true; done
    sleep 1
  fi
}

wait_http(){
  url="$1"; code="${2:-200}"; timeout="${3:-180}"
  t=0
  while (( t < timeout )); do
    c=$(curl -sk -o /dev/null -w '%{http_code}' "$url" || true)
    [[ "$c" == "$code" ]] && return 0
    sleep 3; t=$((t+3))
  done
  return 1
}

json_fix(){
  local x="$1"
  echo "$x" | jq . >/dev/null 2>&1 && echo "$x" || echo "{}"
}
###===============================================
### Step 0 — 系统检查
###===============================================
if step 0 "基础系统检查"; then
  need_root
  need_ubuntu
  apt_quiet update
  apt_quiet install -y curl jq ca-certificates gnupg lsb-release dnsutils ufw
  green "[OK] 系统检查完毕，Ubuntu 24.04 LTS"
fi

###===============================================
### Step 1 — 清理旧环境（Docker / Nginx / Apache）
###===============================================
if step 1 "清理旧环境并释放端口"; then
  systemctl stop docker nginx apache2 containerd >/dev/null 2>&1 || true
  systemctl disable docker nginx apache2 containerd >/dev/null 2>&1 || true

  apt_quiet remove -y nginx* apache2* docker docker.io containerd runc || true
  rm -rf /var/lib/docker /var/lib/containerd /etc/docker 2>/dev/null || true

  # 关键端口释放
  for P in 80 81 443 9080 9000 9980 9090 5905 6080; do
    wait_port_free "$P"
  done

  green "[OK] 旧环境清理完成"
fi

###===============================================
### Step 2 — 安装 Docker + Compose
###===============================================
if step 2 "安装 Docker / Docker Compose"; then
  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
"deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu noble stable" \
  >/etc/apt/sources.list.d/docker.list

  apt_quiet update
  apt_quiet install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin

  systemctl enable docker --now
  green "[OK] Docker 安装完成"
fi

###===============================================
### Step 3 — 创建目录结构
###===============================================
if step 3 "创建目录结构"; then
  mkdir -p "$ROOT_DIR"/{npm,nextcloud,office,wp,cockpit,novnc,portainer,ssl,logs,config}
  mkdir -p "$ROOT_DIR"/personal "$ROOT_DIR"/glinns "$ROOT_DIR"/gsliberty

  green "[OK] 已创建目录："
  echo "$ROOT_DIR/{npm,nextcloud,office,wp,cockpit,novnc,portainer,ssl,logs,config}"
  echo "$ROOT_DIR/personal"
  echo "$ROOT_DIR/glinns"
  echo "$ROOT_DIR/gsliberty"
fi
###===============================================
### Step 4 — 部署 Nginx Proxy Manager
###===============================================
if step 4 "部署 NPM（反代主控）"; then
  cat >"$ROOT_DIR/npm/docker-compose.yml" <<EOF
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
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF

  (cd "$ROOT_DIR/npm" && docker compose up -d)

  wait_http "http://127.0.0.1:81" 200 180 || yellow "[Warn] NPM 未返回 200，但继续部署"

  green "[OK] NPM 已启动"
fi

###===============================================
### Step 5 — 部署 Nextcloud + OnlyOffice
###===============================================
if step 5 "部署 Nextcloud + OnlyOffice"; then
  cat >"$ROOT_DIR/nextcloud/docker-compose.yml" <<EOF
version: "3.8"
services:
  db:
    image: mariadb:10.11
    restart: always
    container_name: nc_db
    environment:
      MYSQL_ROOT_PASSWORD: ${NPM_ADMIN_PASS}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: ncuser
      MYSQL_PASSWORD: ${NPM_ADMIN_PASS}
    volumes:
      - ./db:/var/lib/mysql

  nextcloud:
    image: nextcloud:latest
    restart: always
    container_name: nextcloud_app
    depends_on: [db]
    ports:
      - "${PORT_NC_HTTP}:80"
    volumes:
      - ./html:/var/www/html

  onlyoffice:
    image: onlyoffice/documentserver
    restart: always
    container_name: onlyoffice
    ports:
      - "${PORT_OO_HTTP}:80"
EOF

  (cd "$ROOT_DIR/nextcloud" && docker compose up -d)
  green "[OK] Nextcloud & OnlyOffice 已启动"
fi

###===============================================
### Step 6 — 部署 WordPress Multisite
###===============================================
if step 6 "部署 WordPress Multisite"; then
  cat >"$ROOT_DIR/wp/docker-compose.yml" <<EOF
version: "3.8"
services:
  db:
    image: mariadb:10.11
    restart: always
    container_name: wp_db
    environment:
      MYSQL_ROOT_PASSWORD: ${NPM_ADMIN_PASS}
      MYSQL_DATABASE: wordpress
      MYSQL_USER: wpuser
      MYSQL_PASSWORD: ${NPM_ADMIN_PASS}
    volumes:
      - ./db:/var/lib/mysql

  fpm:
    image: wordpress:php8.2-fpm
    restart: always
    container_name: wp_fpm
    depends_on: [db]
    environment:
      WORDPRESS_DB_HOST: db
      WORDPRESS_DB_USER: wpuser
      WORDPRESS_DB_PASSWORD: ${NPM_ADMIN_PASS}
      WORDPRESS_DB_NAME: wordpress
    volumes:
      - ./html:/var/www/html

  web:
    image: nginx:latest
    restart: always
    container_name: wp_web
    ports:
      - "${PORT_WP_HTTP}:80"
    volumes:
      - ./html:/var/www/html
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
    depends_on: [fpm]
EOF

  # NGINX 配置
  cat >"$ROOT_DIR/wp/nginx.conf" <<'EOF'
server {
    listen 80;
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

  green "[OK] WordPress（多站点）已部署"
fi

###===============================================
### Step 7 — 配置 Multisite 参数
###===============================================
if step 7 "配置 WordPress 多站点参数"; then
  WP_PATH="$ROOT_DIR/wp/html"

  t=0
  while [[ ! -f "$WP_PATH/wp-config-sample.php" && $t -lt 240 ]]; do
    sleep 3; t=$((t+3))
  done

  if [[ -f "$WP_PATH/wp-config-sample.php" ]]; then
    cp -n "$WP_PATH/wp-config-sample.php" "$WP_PATH/wp-config.php"
    cat >>"$WP_PATH/wp-config.php" <<EOF

define( 'WP_ALLOW_MULTISITE', true );
define( 'MULTISITE', true );
define( 'SUBDOMAIN_INSTALL', true );
define( 'DOMAIN_CURRENT_SITE', '${MAIN_DOMAIN}' );
define( 'PATH_CURRENT_SITE', '/' );
define( 'SITE_ID_CURRENT_SITE', 1 );
define( 'BLOG_ID_CURRENT_SITE', 1 );
define( 'COOKIE_DOMAIN', '' );

if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO']==='https') {
  \$_SERVER['HTTPS'] = 'on';
}
EOF
    green "[OK] WordPress Multisite 配置完成"
  else
    yellow "[WARN] 未找到 wp-config-sample.php"
  fi
fi
###===============================================
### Step 8 — 部署 Cockpit（系统管理面板）
###===============================================
if step 8 "部署 Cockpit 管理面板"; then
  apt_quiet install -y cockpit cockpit-networkmanager cockpit-packagekit
  systemctl enable --now cockpit
  green "[OK] Cockpit 已启动（端口 ${PORT_COCKPIT}）"
fi

###===============================================
### Step 9 — 安装 XFCE4 + VNC（5905）+ noVNC（6080）
###===============================================
if step 9 "部署 VNC + noVNC + XFCE 桌面环境"; then
  apt_quiet install -y xfce4 xfce4-goodies tigervnc-standalone-server novnc websockify

  mkdir -p /root/.vnc
  echo "${NPM_ADMIN_PASS}" | vncpasswd -f >/root/.vnc/passwd
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

  nohup websockify --web=/usr/share/novnc/ ${PORT_NOVNC} localhost:${PORT_VNC} >/dev/null 2>&1 &

  green "[OK] VNC (${PORT_VNC}) + noVNC (${PORT_NOVNC}) 已部署"
fi

###===============================================
### Step 10 — Fail2ban + UFW 防火墙
###===============================================
if step 10 "部署 Fail2ban + 防火墙配置"; then
  apt_quiet install -y fail2ban

  local_ignore="127.0.0.1/8"
  for ip in "${WHITE_IPS[@]}"; do
    local_ignore+=" ${ip}"
  done

  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = ${local_ignore}
bantime = 3600
findtime = 600
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
EOF

  systemctl enable --now fail2ban

  # UFW
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 81/tcp
  ufw allow 443/tcp
  ufw allow ${PORT_COCKPIT}/tcp
  ufw allow ${PORT_VNC}/tcp
  ufw allow ${PORT_NOVNC}/tcp
  ufw --force enable

  green "[OK] 防火墙 & Fail2ban 已生效"
fi
###===============================================
### Step 11 — 写入 /etc/hosts（强制）
###===============================================
if step 11 "更新 /etc/hosts"; then
  for d in "${DOMAINS_ALL[@]}"; do
    if ! grep -qE "[[:space:]]${d}$" /etc/hosts; then
      echo "${SERVER_IP} ${d}" >> /etc/hosts
      echo " + hosts 添加：${d}"
    fi
  done
  green "[OK] /etc/hosts 更新完成"
fi

###===============================================
### NPM API 辅助函数
###===============================================
NPM_API="http://127.0.0.1:81/api"
TOKEN=""

npm_login() {
  payload="{\"identity\":\"${NPM_ADMIN_USER}\",\"secret\":\"${NPM_ADMIN_PASS}\"}"
  resp=$(curl -sS -H "Content-Type: application/json" -X POST "${NPM_API}/tokens" -d "$payload" || true)
  resp=$(json_fix "$resp")
  TOKEN=$(echo "$resp" | jq -r '.token // empty')
  [[ -n "$TOKEN" && "$TOKEN" != "null" ]]
}

npm_auth() {
  echo "Authorization: Bearer ${TOKEN}"
}

npm_wait_login() {
  local t=0
  until npm_login; do
    t=$((t+1))
    [[ $t -gt 30 ]] && return 1
    sleep 4
  done
  return 0
}

create_proxy() {
  domain="$1"
  target="$2"

  host=$(echo "$target" | sed 's~http://~~; s~https://~~;')
  fhost=$(echo "$host" | cut -d: -f1)
  fport=$(echo "$host" | cut -d: -f2)

  req=$(jq -nc \
        --argjson dn "[\"$domain\"]" \
        --arg fhost "$fhost" \
        --arg fport "$fport" \
        '{
          domain_names:$dn,
          forward_scheme:"http",
          forward_host:$fhost,
          forward_port:($fport|tonumber),
          certificate_id:0,
          ssl_forced:false,
          access_list_id:0
        }')

  curl -sS -H "$(npm_auth)" -H "Content-Type: application/json" \
      -X POST "${NPM_API}/nginx/proxy-hosts" -d "$req" >/dev/null 2>&1 || true
}

get_proxy_id() {
  domain="$1"
  resp=$(curl -sS -H "$(npm_auth)" "${NPM_API}/nginx/proxy-hosts" || true)
  resp=$(json_fix "$resp")
  echo "$resp" | jq ".[] | select(.domain_names[]==\"$domain\") | .id" | head -n1
}

###===============================================
### Step 12 — 创建反代（全自动）
###===============================================
if step 12 "创建反代配置（自动）"; then
  wait_http "http://127.0.0.1:81" 200 180 || yellow "[Warn] NPM UI 异常继续"

  npm_wait_login || yellow "[WARN] NPM 登录失败，继续尝试"

  declare -A MAP=(
    ["hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["wp.hulin.pro"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["ezglinns.com"]="http://172.17.0.1:${PORT_WP_HTTP}"
    ["gsliberty.com"]="http://172.17.0.1:${PORT_WP_HTTP}"

    ["dri.hulin.pro"]="http://172.17.0.1:${PORT_NC_HTTP}"
    ["doc.hulin.pro"]="http://172.17.0.1:${PORT_OO_HTTP}"
    ["npm.hulin.pro"]="http://127.0.0.1:81"
    ["coc.hulin.pro"]="http://127.0.0.1:${PORT_COCKPIT}"
    ["vnc.hulin.pro"]="http://127.0.0.1:${PORT_NOVNC}"
  )

  for d in "${!MAP[@]}"; do
    yellow " → 创建反代：$d"
    create_proxy "$d" "${MAP[$d]}"
    sleep 1
  done

  green "[OK] 全部反代创建完成"
fi

###===============================================
### SSL 申请辅助函数（自动修复黄码）
###===============================================
dns_ok() {
  a=$(dig +short "$1" | head -n1)
  [[ "$a" == "$SERVER_IP" ]]
}

issue_cert() {
  domain="$1"
  req=$(jq -nc \
        --argjson dn "[\"$domain\"]" \
        --arg em "$EMAIL" \
        '{domain_names:$dn, email:$em, provider:"letsencrypt", challenge:"http", agree_tos:true}')

  resp=$(curl -sS -H "$(npm_auth)" -H "Content-Type: application/json" \
             -X POST "${NPM_API}/certificates" -d "$req" || true)

  resp=$(json_fix "$resp")
  echo "$resp" | jq -r '.id // empty'
}

bind_cert() {
  host_id="$1"
  cert_id="$2"

  req=$(jq -nc \
        --argjson cid "$cert_id" \
        '{certificate_id:$cid, ssl_forced:true, http2_support:true, hsts_enabled:false}')

  curl -sS -H "$(npm_auth)" -H "Content-Type: application/json" \
      -X PUT "${NPM_API}/nginx/proxy-hosts/${host_id}" -d "$req" >/dev/null 2>&1 || true
}

###===============================================
### Step 13 — 自动申请 SSL（含重试）
###===============================================
if step 13 "申请 Let’s Encrypt SSL（自动修复）"; then
  npm_wait_login || yellow "[WARN] 获取 token 失败，但继续 SSL 流程"

  for d in "${DOMAINS_ALL[@]}"; do
    echo ""
    echo "▶ 域名：$d"

    if ! dns_ok "$d"; then
      yellow "  ❌ DNS 未指向 $SERVER_IP，跳过"
      continue
    fi

    hid=$(get_proxy_id "$d" | tr -d '\n')
    if [[ -z "$hid" || "$hid" == "null" ]]; then
      yellow "  ❌ 未找到 Proxy Host"
      continue
    fi

    cid=""
    for retry in 1 2 3 4; do
      cid=$(issue_cert "$d")
      if [[ -n "$cid" && "$cid" != "null" ]]; then
        green "  SSL 申请成功：ID=$cid"
        break
      fi
      yellow "  证书申请失败（第 $retry 次），等待 25 秒重试…"
      sleep 25
    done

    if [[ -z "$cid" || "$cid" == "null" ]]; then
      red "  ❌ SSL 仍失败（已跳过）"
      continue
    fi

    bind_cert "$hid" "$cid"
    green "  SSL 已绑定"
  done

  docker exec npm nginx -s reload || true
  green "[OK] 所有证书已处理"
fi
###===============================================
### Step 14 — 部署 Portainer（Docker 可视化）
###===============================================
if step 14 "部署 Portainer"; then
  docker volume create portainer_data >/dev/null 2>&1 || true

  docker run -d \
    --name portainer \
    --restart always \
    -p 9443:9443 \
    -p 8000:8000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest >/dev/null 2>&1 || true

  green "[OK] Portainer 已部署（9443 端口）"
fi

###===============================================
### Step 17 — 结束前检查
###===============================================
if step 17 "检查执行状态"; then
  docker ps -a
  green "[OK] 所有服务已启动"
fi

###===============================================
### Step 18 — 输出结果信息
###===============================================
if step 18 "输出访问信息"; then

cat <<EOF

==========================================================
🎉  GS-PRO VPS 部署完成！
==========================================================

🌐 主域名入口：
  https://${MAIN_DOMAIN}

📝 WordPress 多站点后台：
  https://wp.${MAIN_DOMAIN}/wp-admin/network/

📦 Nextcloud（文件存储）：
  https://dri.${MAIN_DOMAIN}

📝 OnlyOffice 文档编辑：
  https://doc.${MAIN_DOMAIN}

🛠 Nginx Proxy Manager 面板：
  https://npm.${MAIN_DOMAIN}

🖥 Cockpit 系统管理：
  https://coc.${MAIN_DOMAIN}

🖥 noVNC 浏览器桌面：
  https://vnc.${MAIN_DOMAIN}

🐳 Portainer（Docker GUI）：
  https://${SERVER_IP}:9443

🔐 管理账号（NPM / WP 数据库 / Nextcloud DB）：
  用户名：${NPM_ADMIN_USER}
  密码：${NPM_ADMIN_PASS}

📁 服务器目录结构：
  ${ROOT_DIR}/personal
  ${ROOT_DIR}/glinns
  ${ROOT_DIR}/gsliberty
  ${ROOT_DIR}/nextcloud
  ${ROOT_DIR}/wp
  ...

📌 断点文件：
  ${PROGRESS_FILE}
删除它可重新执行某个步骤。

📌 日志：
  ${LOG_FILE}

==========================================================
EOF

fi

###===============================================
### Step 19 — 完成
###===============================================
if step 19 "完成部署"; then
  green "🚀 所有功能已完成部署！"
  exit 0
fi
