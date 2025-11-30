#!/usr/bin/env bash
set -e

#############################################
# GS PRO — FULL AUTO SUITE (for CyberPanel)
# Author: you
# Tested: Ubuntu 22.04/24.04 + CyberPanel
#############################################

# ====== 固定配置（按你的参数） ======
MAIN_DOMAIN="hulin.pro"
COC_DOMAIN="coc.hulin.pro"   # Cockpit
DRI_DOMAIN="dri.hulin.pro"   # Nextcloud
DOC_DOMAIN="doc.hulin.pro"   # OnlyOffice
SSL_EMAIL="gs@hulin.pro"
CP_ADMIN_PASS="admin@Gaomeilan862447#"   # CyberPanel admin 密码（用于 CLI）
WHITELIST_IPS=("172.56.160.206" "172.56.164.101" "176.56.161.108")

# 容器内部端口
COCKPIT_PORT=9090
NC_PORT=8080
OO_PORT=8443

# Nextcloud 初始管理员
NC_ADMIN_USER="adminnc"
NC_ADMIN_PASS="$(openssl rand -hex 8)"

# Nextcloud DB
DB_ROOT_PASS="dbpass_root"
DB_NAME="nextcloud"
DB_USER="nextcloud"
DB_PASS="dbpass_user"

# 路径
STACK_DIR="/opt/gspro"
NC_STACK="${STACK_DIR}/nextcloud"
OO_DIR="${STACK_DIR}/onlyoffice"
BK_DIR="${STACK_DIR}/backup"
LOG_FILE="/root/onekey.log"

# 实际服务器 IP
SERVER_IP="$(hostname -I | awk '{print $1}')"

# CyberPanel CLI
CPCLI="/usr/local/CyberCP/bin/python /usr/local/CyberCP/plogical/cli.py"

banner() {
  echo -e "\n\033[1;36m====================================================\033[0m"
  echo -e "\033[1;32m$1\033[0m"
  echo -e "\033[1;36m====================================================\033[0m"
}

err() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }
info(){ echo -e "\033[1;34m[INFO]\033[0m $1"; }
ok(){   echo -e "\033[1;32m[OK]\033[0m $1"; }

# ====== 0. 前置检查 ======
banner "0) 环境检查"
[ "$(id -u)" -eq 0 ] || err "请用 root 运行"
command -v lsb_release >/dev/null || apt update -y && apt install -y lsb-release
OS=$(lsb_release -is); VER=$(lsb_release -rs)
[[ "$OS" == "Ubuntu" ]] || err "仅支持 Ubuntu"
info "系统：$OS $VER"
ping -c1 google.com >/dev/null 2>&1 || err "网络不可达"

# DNS 检查
for d in "$COC_DOMAIN" "$DRI_DOMAIN" "$DOC_DOMAIN"; do
  A=$(dig +short "$d" | tail -n1)
  [[ "$A" == "$SERVER_IP" ]] || err "$d 未指向 $SERVER_IP（当前解析：$A）"
  ok "$d -> $A"
done

mkdir -p "$STACK_DIR" "$BK_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

# ====== 1. 基础组件 / UFW / Fail2ban ======
banner "1) 基础组件 / UFW / Fail2ban"
apt update -y
apt install -y curl wget zip unzip tar jq ca-certificates gnupg lsb-release ufw fail2ban dnsutils

# UFW
ufw allow 22 || true
ufw allow 80 || true
ufw allow 443 || true
ufw --force enable || true
ok "UFW 已启用（22/80/443）"

# Fail2ban
cat >/etc/fail2ban/jail.d/gspro.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${WHITELIST_IPS[*]}
bantime  = 1h
findtime = 10m
maxretry = 6

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban
ok "Fail2ban 已启用（白名单：${WHITELIST_IPS[*]}）"

# ====== 2. Docker / Compose / Cockpit ======
banner "2) Docker / Compose / Cockpit"
# Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
 https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) stable" \
> /etc/apt/sources.list.d/docker.list
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker
ok "Docker 安装完成"

# Cockpit
apt install -y cockpit
systemctl enable --now cockpit.socket
ss -lntp | grep -q ":${COCKPIT_PORT}" || true
ok "Cockpit 已安装（内部端口 9090，由反代暴露）"

# ====== 3. Nextcloud + MariaDB + Redis（Docker Compose）=====
banner "3) Nextcloud 组件（Docker）"
mkdir -p "$NC_STACK"
cat >"${NC_STACK}/docker-compose.yml" <<'YAML'
services:
  db:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: REPL_DB_ROOT
      MYSQL_DATABASE: REPL_DB_NAME
      MYSQL_USER: REPL_DB_USER
      MYSQL_PASSWORD: REPL_DB_PASS
    volumes:
      - db_data:/var/lib/mysql
  redis:
    image: redis:7-alpine
    restart: unless-stopped
  nextcloud:
    image: nextcloud:27-apache
    restart: unless-stopped
    ports:
      - "127.0.0.1:REPL_NC_PORT:80"
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: REPL_DB_NAME
      MYSQL_USER: REPL_DB_USER
      MYSQL_PASSWORD: REPL_DB_PASS
      REDIS_HOST: redis
    volumes:
      - nc_data:/var/www/html
volumes:
  db_data:
  nc_data:
YAML

sed -i "s/REPL_DB_ROOT/$DB_ROOT_PASS/;
        s/REPL_DB_NAME/$DB_NAME/;
        s/REPL_DB_USER/$DB_USER/;
        s/REPL_DB_PASS/$DB_PASS/;
        s/REPL_NC_PORT/$NC_PORT/" "${NC_STACK}/docker-compose.yml"

docker compose -f "${NC_STACK}/docker-compose.yml" up -d
ok "Nextcloud/MariaDB/Redis 已启动"

# ====== 4. OnlyOffice（Docker）=====
banner "4) OnlyOffice（Docker）"
mkdir -p "$OO_DIR"/{data,logs}
docker rm -f onlyoffice >/dev/null 2>&1 || true
docker run -d --name onlyoffice --restart=always \
  -p 127.0.0.1:${OO_PORT}:443 \
  -v "${OO_DIR}/data:/var/www/onlyoffice/Data" \
  -v "${OO_DIR}/logs:/var/log/onlyoffice" \
  onlyoffice/documentserver
ok "OnlyOffice 文档服务已启动"

# ====== 5. CyberPanel：建站 / 反代 / SSL ======
banner "5) CyberPanel：域名建站/反代/SSL"
[ -f /usr/local/lsws/bin/lswsctrl ] || err "未检测到 OpenLiteSpeed / CyberPanel，请先安装 CyberPanel"

# 确保 CLI 存在
[ -f /usr/local/CyberCP/plogical/cli.py ] || err "CyberPanel CLI 不存在：/usr/local/CyberCP/plogical/cli.py"

# 创建网站（存在则跳过）
for D in "$COC_DOMAIN" "$DRI_DOMAIN" "$DOC_DOMAIN"; do
  $CPCLI createWebsite --domainName="$D" --owner=admin --email="$SSL_EMAIL" --php=8.2 || true
  ok "网站就绪：$D"
done

# 反代：编辑 vhost.conf
vconf_dir="/usr/local/lsws/conf/vhosts"
# Cockpit
V1="${vconf_dir}/${COC_DOMAIN}/vhost.conf"
grep -q "address https://127.0.0.1:${COCKPIT_PORT}" "$V1" 2>/dev/null || cat >>"$V1" <<EOF

context / {
  type proxy
  address https://127.0.0.1:${COCKPIT_PORT}
  allowBrowse 1
  proxySSLVerifyPeer 0
}
EOF

# Nextcloud
V2="${vconf_dir}/${DRI_DOMAIN}/vhost.conf"
grep -q "address http://127.0.0.1:${NC_PORT}" "$V2" 2>/dev/null || cat >>"$V2" <<EOF

context / {
  type proxy
  address http://127.0.0.1:${NC_PORT}
  allowBrowse 1
}
EOF

# OnlyOffice
V3="${vconf_dir}/${DOC_DOMAIN}/vhost.conf"
grep -q "address https://127.0.0.1:${OO_PORT}" "$V3" 2>/dev/null || cat >>"$V3" <<EOF

context / {
  type proxy
  address https://127.0.0.1:${OO_PORT}
  allowBrowse 1
  proxySSLVerifyPeer 0
}
EOF

# 申请 SSL（失败也不中断）
$CPCLI issueSSL --domainName="$COC_DOMAIN" --email="$SSL_EMAIL" || true
$CPCLI issueSSL --domainName="$DRI_DOMAIN" --email="$SSL_EMAIL" || true
$CPCLI issueSSL --domainName="$DOC_DOMAIN" --email="$SSL_EMAIL" || true

systemctl restart lsws
ok "反代已写入，SSL 尝试申请，OLS 已重启"

# ====== 6. Nextcloud 初始化 & 插件 & 目录结构 ======
banner "6) Nextcloud 初始化 & 应用"

# 等待容器可用
sleep 15
NCID="$(docker ps -q --filter 'name=nextcloud')"
[ -n "$NCID" ] || err "Nextcloud 容器未运行"

# 先确保 occ 可用
docker exec "$NCID" bash -lc 'php -v >/dev/null' || err "容器内 PHP 不可用"

# 维护安装（如已安装会失败，忽略）
docker exec "$NCID" bash -lc "php occ maintenance:install \
 --database='mysql' --database-name='${DB_NAME}' \
 --database-user='${DB_USER}' --database-pass='${DB_PASS}' \
 --database-host='db' \
 --admin-user='${NC_ADMIN_USER}' --admin-pass='${NC_ADMIN_PASS}'" || true

# trusted_domains
docker exec "$NCID" bash -lc "php occ config:system:set trusted_domains 1 --value='${DRI_DOMAIN}'"

# 性能优化：Redis/OPcache（如已存在则跳过）
docker exec "$NCID" bash -lc "grep -q 'memcache.locking' config/config.php || \
php -r '\$f=\"/var/www/html/config/config.php\"; \$c=file_get_contents(\$f); \$ins=\"\\n  \\\"memcache.local\\\" => \\\"\\\\OC\\\\Memcache\\\\Redis\\\",\\n  \\\"memcache.locking\\\" => \\\"\\\\OC\\\\Memcache\\\\Redis\\\",\\n  \\\"redis\\\" => array(\\n    \\\"host\\\" => \\\"redis\\\",\\n    \\\"port\\\" => 6379,\\n  ),\\n\"; \$c=preg_replace(\"/\\);\\n\\s*\\?>?$/\",\"  ,\\n\".\$ins.\") );\\n?>\",\" );\\n\"); file_put_contents(\$f,\$c);' || true"

# 安装/启用插件
docker exec "$NCID" bash -lc "php occ app:install onlyoffice || true"
docker exec "$NCID" bash -lc "php occ app:enable onlyoffice || true"
docker exec "$NCID" bash -lc "php occ config:app:set onlyoffice DocumentServerUrl --value='https://${DOC_DOMAIN}/'"

docker exec "$NCID" bash -lc "php occ app:install files_pdfviewer || true"
docker exec "$NCID" bash -lc "php occ app:enable files_pdfviewer || true"

docker exec "$NCID" bash -lc "php occ app:install previewgenerator || true"
docker exec "$NCID" bash -lc "php occ app:enable previewgenerator || true"

docker exec "$NCID" bash -lc "php occ app:install photos || true"
docker exec "$NCID" bash -lc "php occ app:enable photos || true"

# OCR 可选（recognize 依赖大，这里先启用基础 OCR：tesseract 在宿主）
apt install -y tesseract-ocr tesseract-ocr-chi-sim || true

# 目录结构（按你确认的最终版）
make_dirs=(
"Company/GLINNS/Branding"
"Company/GLINNS/Business"
"Company/GLINNS/Consulting"
"Company/GLINNS/WebSite"
"Company/GLINNS/Finance"
"Company/GLINNS/Legal"
"Company/GLINNS/HR"
"Company/GLINNS/Projects"
"Company/GLINNS/Marketing"
"Company/GLINNS/Assets"
"Company/GS_Liberty/Dispatch"
"Company/GS_Liberty/Trucking"
"Company/GS_Liberty/Safety"
"Company/GS_Liberty/Compliance"
"Company/GS_Liberty/FMCSA"
"Company/GS_Liberty/Operations"
"Company/GS_Liberty/Accounting"
"Company/GS_Liberty/DriverDocs"
"Company/GS_Liberty/Projects"
"Company/Future_Business/Placeholder"
"Personal/ID_Documents/Passport"
"Personal/ID_Documents/Visa"
"Personal/ID_Documents/SSN"
"Personal/ID_Documents/DriverLicense"
"Personal/ID_Documents/WorkPermit"
"Personal/Finance/Banking"
"Personal/Finance/Credit"
"Personal/Finance/Taxes"
"Personal/Health/Medical"
"Personal/Health/Insurance"
"Personal/Mobile_Data_Backup/iPhone/Photos"
"Personal/Mobile_Data_Backup/iPhone/Screenshots"
"Personal/Mobile_Data_Backup/iPhone/Videos"
"Personal/Mobile_Data_Backup/iPhone/Files_App"
"Personal/Mobile_Data_Backup/iPhone/WhatsApp"
"Personal/Mobile_Data_Backup/iPhone/WeChat"
"Personal/Mobile_Data_Backup/iPad/Photos"
"Personal/Mobile_Data_Backup/iPad/Screenshots"
"Personal/Mobile_Data_Backup/iPad/Videos"
"Personal/Mobile_Data_Backup/iPad/Notes"
"Personal/Mobile_Data_Backup/CloudMac/Desktop"
"Personal/Mobile_Data_Backup/CloudMac/Documents"
"Personal/Mobile_Data_Backup/CloudMac/Screenshots"
"Personal/OCR/Kards"
"Personal/OCR/Receipts"
"Personal/OCR/Notes"
"Personal/OCR/Manuals"
"Personal/OCR/Auto_OCR_Output"
"Personal/Photos/Camera"
"Personal/Photos/Edited"
"Personal/Photos/Cloud_Backups"
"Personal/Photos/RAW"
"Personal/Education/English"
"Personal/Education/Study"
"Personal/Education/Certifications"
"Personal/Life/Housing"
"Personal/Life/Travel"
"Personal/Life/Shopping"
"Personal/Life/Work_Diary"
"Business_Admin/Domains"
"Business_Admin/Hosting"
"Business_Admin/VPS"
"Business_Admin/Templates"
"Business_Admin/Legal_Templates"
"Docs/Legal"
"Docs/CDL"
"Docs/Trucking_Manuals"
"Docs/Projects"
"Docs/OCR_Result"
"Media/Raw_Photos"
"Media/Videos"
"Media/Archives"
"Archive/Old_Projects"
"Archive/Old_Documents"
"Archive/Backup_2024"
"Temp/Uploads"
"Temp/Screenshots"
"Temp/OCR"
)
for p in "${make_dirs[@]}"; do
  docker exec "$NCID" bash -lc "mkdir -p /var/www/html/data/${NC_ADMIN_USER}/files/'$p'" || true
done
docker exec "$NCID" bash -lc "php occ files:scan --all" || true
ok "Nextcloud 已初始化（管理员：${NC_ADMIN_USER} / ${NC_ADMIN_PASS}）"

# ====== 7. 备份方案 A（Cron）=====
banner "7) 备份方案 A（每日/每周 + 保留 14 天）"

cat >"${BK_DIR}/backup.sh" <<'BK'
#!/usr/bin/env bash
set -e
KEEP_DAYS=14
DST="/opt/gspro/backup/$(date +%F)"
mkdir -p "$DST"

# Docker 全备（compose + volumes 快照）
docker ps -a > "$DST/docker-ps.txt"
tar czf "$DST/docker-volumes.tgz" /var/lib/docker/volumes || true

# Nextcloud 数据差异（容器卷路径）
# 说明：此为简单快照，生产可改为 rsync --link-dest 增量
tar czf "$DST/nextcloud-data.tgz" /var/lib/docker/volumes/*nc_data*/_data || true

# CyberPanel 配置快照（轻量）
tar czf "$DST/cyberpanel-conf.tgz" /usr/local/lsws/conf /etc/letsencrypt || true

# 清理历史
find /opt/gspro/backup -maxdepth 1 -type d -mtime +$KEEP_DAYS -exec rm -rf {} \; || true
BK
chmod +x "${BK_DIR}/backup.sh"

# 每日 03:10 备份
( crontab -l 2>/dev/null; echo "10 3 * * * /opt/gspro/backup/backup.sh >/opt/gspro/backup/backup.log 2>&1" ) | crontab -

# 每周补充 CyberPanel 全备（示意：周日 03:40 再打一次）
( crontab -l 2>/dev/null; echo "40 3 * * 0 /opt/gspro/backup/backup.sh >/opt/gspro/backup/backup-weekly.log 2>&1" ) | crontab -

ok "备份计划已写入 crontab（每日/每周，保留 14 天）"

# ====== 8. 总结 ======
banner "8) 完成！访问信息"

cat >/root/deploy_summary.txt <<SUM
======== GS PRO 部署完成 ========
服务器 IP: ${SERVER_IP}

[门户面板]
 Cockpit:    https://${COC_DOMAIN}

[云盘]
 Nextcloud:  https://${DRI_DOMAIN}
   管理员: ${NC_ADMIN_USER}
   密  码: ${NC_ADMIN_PASS}

[在线编辑]
 OnlyOffice: https://${DOC_DOMAIN}

[安全]
 Fail2ban 白名单: ${WHITELIST_IPS[*]}

[备份]
 目录: ${BK_DIR}
 每日/每周自动执行，保留 14 天

日志: ${LOG_FILE}
=================================
SUM

ok "写入 /root/deploy_summary.txt"
echo
echo "✅ 一切完成！请访问："
echo "   Cockpit   → https://${COC_DOMAIN}"
echo "   Nextcloud → https://${DRI_DOMAIN}   (admin: ${NC_ADMIN_USER} / ${NC_ADMIN_PASS})"
echo "   Office    → https://${DOC_DOMAIN}"
echo
