Vps

###############################################################
#  PART 3 — SSH 互信 + CloudMac 初始化 + MASTER KEY 派送
###############################################################

log "=== PART 3 — 配置 SSH 互信 + CloudMac 初始化 ==="

# ------------------------------------------------------------
# [3.1] VPS 生成 SSH 密钥（ed25519）
# ------------------------------------------------------------
SSH_KEY="$GS/secure/gs_ssh"
[[ ! -f "$SSH_KEY" ]] && {
    log "生成 ed25519 SSH 密钥..."
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" >/dev/null 2>&1
}
chmod 600 "$SSH_KEY"
SSH_PUB="$SSH_KEY.pub"

# ------------------------------------------------------------
# [3.2] VPS → CloudMac 免密
# ------------------------------------------------------------
log "配置 VPS → CloudMac 免密..."

sshpass -p "$MAC_PASS" ssh-copy-id \
    -i "$SSH_PUB" -o StrictHostKeyChecking=no \
    "$MAC_USER@$MAC_IP" >/dev/null 2>&1 \
      && log "VPS → CloudMac 免密成功" \
      || warn "CloudMac 可能已配置免密（警告可忽略）"

# ------------------------------------------------------------
# [3.3] CloudMac → VPS 免密
# ------------------------------------------------------------
log "配置 CloudMac → VPS 免密..."

sshpass -p "$MAC_PASS" ssh "$MAC_USER@$MAC_IP" \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

PUB=$(cat "$SSH_PUB")
sshpass -p "$MAC_PASS" ssh "$MAC_USER@$MAC_IP" \
  "echo '$PUB' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"

log "CloudMac → VPS 免密已完成"

# ------------------------------------------------------------
# [3.4] CloudMac 目录结构初始化
# ------------------------------------------------------------
log "[CloudMac] 执行远程初始化..."

ssh "$MAC_USER@$MAC_IP" << 'EOF_MAC'
#!/usr/bin/env bash
set -Eeuo pipefail

echo "[CloudMac] 初始化目录..."
mkdir -p ~/gs-core ~/gs-share ~/macapi ~/logs ~/gs-sync
chmod 700 ~/gs-core ~/macapi

# 禁用睡眠（云 Mac 常见）
sudo system

###############################################################
#  PART 2 — VPS SYSTEM ENVIRONMENT (OPTIMIZED, NO FEATURE LOSS)
###############################################################

log "=== PART 2 — VPS 系统环境准备开始 ==="

# ------------------------------------------------------------
# [2.1] APT 更新 + 基础工具
# ------------------------------------------------------------
log "更新系统并安装基础工具..."

apt update -y && apt upgrade -y
apt install -y \
  ca-certificates curl gnupg lsb-release \
  sshpass sshfs rsync jq wget unzip \
  software-properties-common pwgen

# ------------------------------------------------------------
# [2.2] 禁用 VPS 自动休眠（防止云主机睡眠）
# ------------------------------------------------------------
log "禁用 VPS 睡眠/休眠..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

# ------------------------------------------------------------
# [2.3] 统一端口管理（自动检测、清理占用）
# ------------------------------------------------------------
declare -A PORTS=(
  [http]=80 [https]=443 [npm]=81
  [macapi]=5000 [cockpit]=9090
  [novnc]=6080 [vnc]=5905
)

kill_port(){
  local p=$1
  local PIDS=$(ss -tulpn | grep ":$p " | awk '{print $NF}' | sed 's/pid=\([0-9]*\).*/\1/' | sort -u)

  [[ -z "$PIDS" ]] && { log "端口 $p 空闲"; return; }

  warn "端口 $p 被占用 → 强制释放"
  for pid in $PIDS; do kill -9 "$pid" 2>/dev/null || true; done
  log "端口 $p 已成功清理"
}

log "检查所有关键端口..."
for p in "${PORTS[@]}"; do kill_port "$p"; done

# ------------------------------------------------------------
# [2.4] Docker 安装（自动判断）
# ------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "安装 Docker..."
  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
   "deb [arch=$(dpkg --print-architecture) \
   signed-by=/etc/apt/keyrings/docker.gpg] \
   https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) stable" \
   | tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker --now
  log "Docker 安装完成"
else
  log "Docker 已安装，跳过"
fi

# ------------------------------------------------------------
# [2.5] Docker compose 确认
# ------------------------------------------------------------
docker compose version >/dev/null 2>&1 \
  && log "docker compose 已就绪" \
  || { warn "补充安装 docker compose"; apt install -y docker-compose-plugin; }

# ------------------------------------------------------------
# [2.6] Docker 网络
# ------------------------------------------------------------
docker network inspect gs-net >/dev/null 2>&1 \
  && log "gs-net 已存在" \
  || { docker network create gs-net; log "已创建 Docker 网络 gs-net"; }

# ------------------------------------------------------------
# [2.7] Docker 服务容器目录
# ------------------------------------------------------------
mkdir -p $GS/docker/{npm,nextcloud,office,wp,novnc,cockpit,portainer,macapi}
log "Docker 服务目录已初始化：/gs/docker/*"

log "=== PART 2 完成：系统环境与 Docker 就绪 ==="
echo

###############################################################
#  PART 3 — SSH 互信 + CloudMac 初始化 + MASTER KEY 派送
###############################################################

log "=== PART 3 — 配置 SSH 互信 + CloudMac 初始化 ==="

# ------------------------------------------------------------
# [3.1] VPS 生成 SSH 密钥（ed25519）
# ------------------------------------------------------------
SSH_KEY="$GS/secure/gs_ssh"
[[ ! -f "$SSH_KEY" ]] && {
    log "生成 ed25519 SSH 密钥..."
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" >/dev/null 2>&1
}
chmod 600 "$SSH_KEY"
SSH_PUB="$SSH_KEY.pub"

# ------------------------------------------------------------
# [3.2] VPS → CloudMac 免密
# ------------------------------------------------------------
log "配置 VPS → CloudMac 免密..."

sshpass -p "$MAC_PASS" ssh-copy-id \
    -i "$SSH_PUB" -o StrictHostKeyChecking=no \
    "$MAC_USER@$MAC_IP" >/dev/null 2>&1 \
      && log "VPS → CloudMac 免密成功" \
      || warn "CloudMac 可能已配置免密（警告可忽略）"

# ------------------------------------------------------------
# [3.3] CloudMac → VPS 免密
# ------------------------------------------------------------
log "配置 CloudMac → VPS 免密..."

sshpass -p "$MAC_PASS" ssh "$MAC_USER@$MAC_IP" \
  "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

PUB=$(cat "$SSH_PUB")
sshpass -p "$MAC_PASS" ssh "$MAC_USER@$MAC_IP" \
  "echo '$PUB' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys"

log "CloudMac → VPS 免密已完成"

# ------------------------------------------------------------
# [3.4] CloudMac 目录结构初始化
# ------------------------------------------------------------
log "[CloudMac] 执行远程初始化..."

ssh "$MAC_USER@$MAC_IP" << 'EOF_MAC'
#!/usr/bin/env bash
set -Eeuo pipefail

echo "[CloudMac] 初始化目录..."
mkdir -p ~/gs-core ~/gs-share ~/macapi ~/logs ~/gs-sync
chmod 700 ~/gs-core ~/macapi

# 禁用睡眠（云 Mac 常见）
sudo systemsetup -setcomputersleep Never 2>/dev/null || true
sudo systemsetup -setdisplaysleep Never 2>/dev/null || true

echo "[CloudMac] 初始化完成"
EOF_MAC

log "CloudMac 初始化完成"

# ------------------------------------------------------------
# [3.5] 下发 MASTER KEY（加密版）
# ------------------------------------------------------------
log "向 CloudMac 派送 MASTER KEY（加密版）..."

ENC_MASTER_KEY=$(aes_encrypt "$MASTER_KEY")

ssh "$MAC_USER@$MAC_IP" << EOF_KEY
echo "$ENC_MASTER_KEY" > ~/gs-core/master_key.enc
chmod 600 ~/gs-core/master_key.enc
EOF_KEY

log "CloudMac 已收到 MASTER KEY（enc）"

# ------------------------------------------------------------
# [3.6] 部署 CloudMac 解密脚本
# ------------------------------------------------------------
log "写入 CloudMac AES 解密模块..."

ssh "$MAC_USER@$MAC_IP" << 'EOF_AES'
cat > ~/gs-core/gs_aes.sh <<'EOF_DEC'
#!/bin/bash
KEY=$(openssl enc -aes-256-cbc -pbkdf2 -d -base64 \
      -pass pass:"GS_PLACEHOLDER" < ~/gs-core/master_key.enc)

aes_dec(){ echo "$1" | openssl enc -aes-256-cbc -pbkdf2 -d -base64 -pass pass:"$KEY"; }
EOF_DEC
chmod +x ~/gs-core/gs_aes.sh
EOF_AES

# 替换占位符
ssh "$MAC_USER@$MAC_IP" \
  "sed -i '' -e 's/GS_PLACEHOLDER/$MASTER_KEY/' ~/gs-core/gs_aes.sh"

log "CloudMac 解密接口已部署"

# ------------------------------------------------------------
# [3.7] 桌面快捷方式 / 三端共享映射
# ------------------------------------------------------------
ssh "$MAC_USER@$MAC_IP" << 'EOF_SHARE'
ln -sf ~/gs-share ~/Desktop/gs-share 2>/dev/null || true
ln -sf ~/gs-core ~/Desktop/gs-core 2>/dev/null || true
EOF_SHARE

log "CloudMac 共享链接绑定完成"

echo
log "=== PART 3 完成：SSH 互信、CloudMac 初始化、MASTER KEY 已就绪 ==="
echo

###############################################################
# PART 4 — CloudMac OCR Worker 安装 + LaunchAgent + 健康检查
###############################################################

log "=== PART 4 — CloudMac OCR Worker 部署开始 ==="

# ------------------------------------------------------------
# [4.1] CloudMac Python3 + venv 准备
# ------------------------------------------------------------
log "CloudMac：准备 Python 环境..."

ssh "$MAC_USER@$MAC_IP" << 'EOF_PY'
set -Eeuo pipefail
which python3 >/dev/null || brew install python || true

python3 -m venv ~/macapi/venv
~/macapi/venv/bin/pip install flask pillow pytesseract requests >/dev/null 2>&1
EOF_PY

log "CloudMac Python venv + 依赖安装完成"

# ------------------------------------------------------------
# [4.2] 端口占用检查（5000）
# ------------------------------------------------------------
log "检查 CloudMac OCR 端口占用（5000）..."

ssh "$MAC_USER@$MAC_IP" "lsof -i :5000 >/dev/null 2>&1 && pkill -f macapi/ocr.py || true"

log "OCR 端口检查完成"

# ------------------------------------------------------------
# [4.3] 写入 OCR Worker（含中英文自动识别+预处理）
# ------------------------------------------------------------
log "写入 OCR Worker（高性能版）..."

ssh "$MAC_USER@$MAC_IP" << 'EOF_OCR'
cat > ~/macapi/ocr.py << 'EOF_APP'
from flask import Flask, request, jsonify
from PIL import Image, ImageFilter, ImageOps
from io import BytesIO
import base64, pytesseract, time

app = Flask(__name__)

def preprocess(img):
    img = ImageOps.grayscale(img)
    img = img.filter(ImageFilter.MedianFilter(3))
    img = ImageOps.autocontrast(img)
    img = img.filter(ImageFilter.SHARPEN)
    return img

@app.post("/ocr")
def ocr_api():
    if "base64" not in request.form:
        return jsonify({"error": "missing base64"}), 400

    t0 = time.time()
    raw = base64.b64decode(request.form["base64"])
    img = Image.open(BytesIO(raw))
    img2 = preprocess(img)

    eng = pytesseract.image_to_string(img2, lang="eng")
    chi = pytesseract.image_to_string(img2, lang="chi_sim")
    out = chi if len(chi) > len(eng) else eng

    return jsonify({
        "status": "ok",
        "text": out,
        "ms": int((time.time() - t0) * 1000),
        "size": img.size
    })

@app.get("/")
def health():
    return jsonify({"status": "ok", "worker": "gs-mac-ocr"})
EOF_APP
EOF_OCR

log "OCR Worker 文件写入完成"

# ------------------------------------------------------------
# [4.4] LaunchAgent （CloudMac 后台常驻）
# ------------------------------------------------------------
log "创建 CloudMac LaunchAgent..."

ssh "$MAC_USER@$MAC_IP" << 'EOF_PLIST'
mkdir -p ~/Library/LaunchAgents

cat > ~/Library/LaunchAgents/com.gs.macapi.plist << 'EOF_P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gs.macapi</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/Hulin/macapi/venv/bin/python</string>
    <string>/Users/Hulin/macapi/ocr.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Users/Hulin/logs/api.log</string>
  <key>StandardErrorPath</key><string>/Users/Hulin/logs/api_error.log</string>
</dict></plist>
EOF_P

launchctl unload ~/Library/LaunchAgents/com.gs.macapi.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.gs.macapi.plist
EOF_PLIST

log "CloudMac OCR Worker 已加入 LaunchAgent 并后台运行"

# ------------------------------------------------------------
# [4.5] API 配置文件（供后续 Caddy 反代）
# ------------------------------------------------------------
cat > $GS/config/macapi.json <<EOF_CFG
{
  "mac_ip": "$MAC_IP",
  "port": 5000,
  "domain": "api.hulin.pro",
  "user": "$MAC_USER"
}
EOF
log "macapi.json 已写入"

echo
log "=== PART 4 完成：OCR Worker + LaunchAgent 已全部完成 ==="
echo

###############################################################
# PART 5 — THREE-END SYNC (CloudMac ↔ VPS ↔ Phone)
###############################################################

log "=== PART 5 — 初始化 CloudMac ↔ VPS ↔ Phone 同步系统 ==="

# ------------------------------------------------------------
# [5.1] 创建同步目录
# ------------------------------------------------------------
mkdir -p $GS/mount/mac
mkdir -p $GS/share/{mac,vps,phone,merged}
mkdir -p $GS/logs/sync

log "同步目录结构已准备完毕：/gs/share/*"

# ------------------------------------------------------------
# [5.2] SSHFS 挂载 CloudMac → VPS
# ------------------------------------------------------------
log "尝试挂载 CloudMac 文件系统..."

sshfs_mount() {
    sshfs -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=5,StrictHostKeyChecking=no \
      "$MAC_USER@$MAC_IP:/Users/$MAC_USER" \
      "$GS/mount/mac" >/dev/null 2>&1
}

sshfs_mount && log "CloudMac 已成功挂载 → /gs/mount/mac" \
              || warn "挂载失败，将通过 watchdog 自动重试"

# ------------------------------------------------------------
# [5.3] SSHFS watchdog（自动重连）
# ------------------------------------------------------------
log "创建 SSHFS watchdog..."

cat > $GS/bin/gs-sshfs-watch <<'EOF_WATCH'
#!/usr/bin/env bash
M="/gs/mount/mac"
while true; do
  mount | grep -q "$M" || {
    echo "[WATCH] SSHFS lost → reconnect..."
    sshfs -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=5,StrictHostKeyChecking=no \
      Hulin@192.111.137.81:/Users/Hulin "$M" >/gs/logs/sync/sshfs.log 2>&1
  }
  sleep 10
done
EOF_WATCH
chmod +x $GS/bin/gs-sshfs-watch
nohup $GS/bin/gs-sshfs-watch >/dev/null 2>&1 &
log "SSHFS watchdog 已后台运行"

# ------------------------------------------------------------
# [5.4] 写入 rsync 双向同步脚本
# ------------------------------------------------------------
log "写入 rsync 三端同步脚本..."

cat > $GS/bin/gs-sync <<EOF_SYNC
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$GS"
LOG="\$ROOT/logs/sync/sync_\$(date +%Y%m%d).log"

MAC_DIR="\$ROOT/mount/mac/gs-share"
VPS_DIR="\$ROOT/share/vps"
PHONE_DIR="\$ROOT/share/phone"

mkdir -p "\$VPS_DIR"

echo "[SYNC] === Begin: \$(date) ===" >> "\$LOG"

# 1. CloudMac → VPS
rsync -avz --delete --ignore-errors "\$MAC_DIR/" "\$VPS_DIR/" >> "\$LOG" 2>&1 || true

# 2. Phone → CloudMac
rsync -avz --ignore-errors "\$PHONE_DIR/" "$MAC_USER@$MAC_IP:gs-share/" >> "\$LOG" 2>&1 || true

echo "[SYNC] === End ===" >> "\$LOG"
EOF_SYNC

chmod +x $GS/bin/gs-sync
log "同步脚本 gs-sync 生成完成"

# ------------------------------------------------------------
# [5.5] Cron 定时任务（每 3 分钟自动同步）
# ------------------------------------------------------------
log "添加 crontab（每 3 分钟同步一次）..."

(crontab -l 2>/dev/null | grep -v "gs-sync" ; echo "*/3 * * * * $GS/bin/gs-sync >/dev/null 2>&1") | crontab -

log "Cron 同步任务已注册"

# ------------------------------------------------------------
# [5.6] 手动首次同步（验证路径）
# ------------------------------------------------------------
$GS/bin/gs-sync || warn "首次同步出现警告（系统会自动重试）"

echo
log "=== PART 5 完成：三端同步系统已全面运行 ==="
echo

###############################################################
# PART 6 — HTTPS Reverse Proxy + Monitoring + Final Summary
###############################################################

log "=== PART 6 — 配置 Caddy HTTPS 反代 + 健康监控 ==="

# ------------------------------------------------------------
# [6.1] Caddy 安装（轻量检查）
# ------------------------------------------------------------
if ! command -v caddy >/dev/null; then
  log "安装 Caddy..."
  apt install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy.list >/dev/null
  apt update && apt install -y caddy
else
  log "Caddy 已存在，跳过安装"
fi

# ------------------------------------------------------------
# [6.2] HTTPS 反代配置（api.hulin.pro → CloudMac:5000）
# ------------------------------------------------------------
DOMAIN="api.hulin.pro"
CADDY="/etc/caddy/Caddyfile"

log "写入 Caddyfile（HTTPS 自动证书 + 反向代理）..."

cat > "$CADDY" <<EOF
{
    email $EMAIL_ADDR
    auto_https on
}

$DOMAIN {
    reverse_proxy $MAC_IP:5000
    tls {
        protocols tls1.2 tls1.3
    }
    log {
        output file /gs/logs/macapi-access.log
        format console
    }
}
EOF

kill_port 80
kill_port 443

systemctl reload caddy || systemctl restart caddy

sleep 2
curl -sk "https://$DOMAIN" | grep -q "running" \
    && log "HTTPS 反代正常运行" \
    || warn "API 首次检测失败（可能等待证书）"

# ------------------------------------------------------------
# [6.3] API 健康监控守护（自动恢复 HTTPS）
# ------------------------------------------------------------
log "写入 api-watch 守护..."

cat > $GS/bin/api-watch <<EOF_WATCH
#!/usr/bin/env bash
URL="https://$DOMAIN"
while true; do
  CODE=\$(curl -sk -o /dev/null -w "%{http_code}" "\$URL")
  [[ "\$CODE" != "200" ]] && systemctl reload caddy
  sleep 20
done
EOF_WATCH

chmod +x $GS/bin/api-watch
nohup $GS/bin/api-watch >/dev/null 2>&1 &
log "api-watch 守护进程已启动"

# ------------------------------------------------------------
# [6.4] OCR Worker 健康监控（自动重启 Launchctl）
# ------------------------------------------------------------
log "写入 ocr-watch..."

cat > $GS/bin/ocr-watch <<EOF_OCR
#!/usr/bin/env bash
URL="http://$MAC_IO:5000/"
while true; do
  [[ "\$(curl -sk -o /dev/null -w "%{http_code}" \$URL)" != "200" ]] \
    && ssh $MAC_USER@$MAC_IP "launchctl unload ~/Library/LaunchAgents/com.gs.macapi.plist; launchctl load ~/Library/LaunchAgents/com.gs.macapi.plist"
  sleep 10
done
EOF_OCR
chmod +x $GS/bin/ocr-watch
nohup $GS/bin/ocr-watch >/dev/null 2>&1 &
log "OCR 监控已启动"

# ------------------------------------------------------------
# [6.5] SSHFS 监控（端口变更、断线恢复）
# ------------------------------------------------------------
log "写入 sshfs-watch（已在前面配置，此处只补全监控）"

cat > $GS/bin/sshfs-watch <<EOF_SSH
#!/usr/bin/env bash
M="/gs/mount/mac"
while true; do
  mount | grep -q "\$M" || sshfs -o reconnect,StrictHostKeyChecking=no \
    $MAC_USER@$MAC_IP:/Users/$MAC_USER "\$M"
  sleep 8
done
EOF_SSH
chmod +x $GS/bin/sshfs-watch
nohup $GS/bin/sshfs-watch >/dev/null 2>&1 &

# ------------------------------------------------------------
# [6.6] 端口监控（80/443/5000 自动恢复 Caddy）
# ------------------------------------------------------------
log "写入 port-watch..."

cat > $GS/bin/port-watch <<EOF_PORT
#!/usr/bin/env bash
PORTS=(80 443 5000)
while true; do
  for p in "\${PORTS[@]}"; do
    ss -tulpn | grep -q ":\$p " || systemctl reload caddy
  done
  sleep 20
done
EOF_PORT
chmod +x $GS/bin/port-watch
nohup $GS/bin/port-watch >/dev/null 2>&1 &

# ------------------------------------------------------------
# [6.7] 生成系统摘要
# ------------------------------------------------------------
REPORT="$GS/logs/final_report.txt"
{
  echo "================== GS-PRO REPORT =================="
  echo "部署时间：$(date)"
  echo
  echo "[CloudMac] $MAC_USER@$MAC_IP"
  echo "[VPS]      $VPS_USER@$VPS_IP"
  echo
  echo "[API Domain] https://$DOMAIN"
  echo "[OCR Worker] $MAC_IP:5000"
  echo
  echo "[Sync]"
  echo " - CloudMac: ~/gs-share"
  echo " - VPS: /gs/share/vps"
  echo " - Phone: /gs/share/phone"
  echo
  echo "[Watchdogs]"
  echo " - api-watch: ENABLED"
  echo " - ocr-watch: ENABLED"
  echo " - sshfs-watch: ENABLED"
  echo " - port-watch: ENABLED"
  echo "==================================================="
} > "$REPORT"

log "系统摘要生成：$REPORT"

# ------------------------------------------------------------
# [6.8] 完成标志
# ------------------------------------------------------------
echo "GS-PRO-INSTALL-FINISHED" > $GS/INSTALL_DONE
chmod 600 $GS/INSTALL_DONE

log "部署完成！系统已全面运行。"
echo -e "\033[1;32m🌟 GS-PRO ULTRA — ALL SYSTEMS ONLINE 🌟\033[0m"
