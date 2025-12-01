#!/bin/bash
set -e

### ========================
### CloudMac → VPS 自动联动版 mac.sh
### 功能：
### - 安装 Homebrew / Python / PaddleOCR
### - 部署 OCR API（5000）
### - 自动注册到 VPS：https://api.hulin.pro/_cloudmac/register
### - 自动上报健康（固定 IP 100.64.0.1）
### - launchctl 守护常驻
### ========================

MAC_PRIVATE_IP="100.64.0.1"
MAC_PUBLIC_IP="192.111.137.81"
MAC_USER="Hulin"
MAC_PASS="NuYh917n8z"
SSH_PORT="22"
NX_PORT="4000"
API_PORT="5000"

VPS_API_URL="https://api.hulin.pro/_cloudmac/register"
APP_DIR="/opt/macapi"
VENV_DIR="$APP_DIR/venv"
LOG_DIR="/var/log/macapi"
SERVICE_FILE="/Library/LaunchDaemons/com.macapi.service.plist"

mkdir -p "$APP_DIR" "$LOG_DIR"

echo "[1/10] 检查 Xcode CLI..."
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
fi

echo "[2/10] 安装 Homebrew..."
if ! command -v brew >/dev/null 2>&1; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

echo "[3/10] 安装 Python + 依赖..."
brew install python@3.11 cmake pkg-config git wget

python3.11 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

pip install --upgrade pip setuptools wheel
pip install flask paddlepaddle paddleocr waitress

echo "[4/10] 安装 OCR API 服务..."
cat > "$APP_DIR/app.py" <<EOF
from paddleocr import PaddleOCR
from flask import Flask, request, jsonify
import base64, tempfile, os

ocr = PaddleOCR(use_angle_cls=True, lang='ch')
app = Flask(__name__)

@app.post("/ocr")
def ocr_api():
    data = request.json.get("image")
    if not data:
        return jsonify({"error":"no image"}),400
    img_bytes = base64.b64decode(data)
    tf = tempfile.NamedTemporaryFile(delete=False, suffix=".jpg")
    tf.write(img_bytes)
    tf.close()
    res = ocr.ocr(tf.name, cls=True)
    os.unlink(tf.name)
    text = []
    if res:
        for line in res:
            for b in line:
                text.append(b[1][0])
    return jsonify({"text": "\n".join(text)})
EOF
echo "[5/10] 创建 Waitress 启动器..."

cat > "$APP_DIR/start_api.sh" <<EOF
#!/bin/bash
source "$VENV_DIR/bin/activate"
exec waitress-serve --host=0.0.0.0 --port=$API_PORT app:app
EOF

chmod +x "$APP_DIR/start_api.sh"

echo "[6/10] 创建 launchctl 守护服务..."

cat > "$SERVICE_FILE" <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.macapi.service</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DIR/start_api.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>$APP_DIR</string>
  <key>StandardOutPath</key><string>$LOG_DIR/macapi.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/macapi.err</string>
</dict>
</plist>
EOF

launchctl unload "$SERVICE_FILE" 2>/dev/null || true
launchctl load "$SERVICE_FILE"

echo "[7/10] 给 API 等待 5 秒初始化..."
sleep 5

echo "[8/10] OCR 自检..."

OCR_TEST_RESULT="FAIL"
TEST_BASE64=$(echo -n "TEST" | base64)

CHECK=$(curl -s -X POST http://127.0.0.1:$API_PORT/ocr \
  -H "Content-Type: application/json" \
  -d "{\"image\":\"$TEST_BASE64\"}" | jq -r '.text // empty')

if [[ -n "$CHECK" ]]; then
  OCR_TEST_RESULT="OK"
fi

echo "OCR Test Result = $OCR_TEST_RESULT"
echo "[9/10] 生成 CloudMac 注册 JSON..."

REGISTER_PAYLOAD=$(cat <<EOF
{
  "mac_ip": "$MAC_PRIVATE_IP",
  "public_ip": "$MAC_PUBLIC_IP",
  "api_port": $API_PORT,
  "ssh_port": $SSH_PORT,
  "nx_port": $NX_PORT,
  "ocr_test": "$OCR_TEST_RESULT",
  "api_status": "running",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

echo "$REGISTER_PAYLOAD" > "$APP_DIR/register.json"

echo "[10/10] 推送注册信息到 VPS..."

attempt=0
MAX_RETRY=10

while [[ $attempt -lt $MAX_RETRY ]]; do
  RESP=$(curl -sk -w "%{http_code}" -o /tmp/macapi_resp.txt \
    -X POST "$VPS_API_URL" \
    -H "Content-Type: application/json" \
    -d "$REGISTER_PAYLOAD")

  if [[ "$RESP" == "200" ]]; then
    echo "注册成功。"
    break
  fi

  echo "注册失败，重试中 ($attempt/$MAX_RETRY)..."
  sleep 5
  attempt=$((attempt+1))
done

### =============================
### 创建健康检查守护任务（每 60 秒）
### =============================

cat > "$APP_DIR/healthcheck.sh" <<EOF
#!/bin/bash

API_PORT=$API_PORT
MAC_PRIVATE_IP="$MAC_PRIVATE_IP"
MAC_PUBLIC_IP="$MAC_PUBLIC_IP"
SSH_PORT=$SSH_PORT
NX_PORT=$NX_PORT

APP_DIR="$APP_DIR"
PAYLOAD_FILE="\$APP_DIR/register.json"
VPS_URL="$VPS_API_URL"

# 1. 检查 API 是否存活
STATUS="running"
CHECK=$(curl -s -X POST http://127.0.0.1:\$API_PORT/ocr -H "Content-Type: application/json" -d '{"image":""}' | jq -r '.error // empty')

if [[ "\$CHECK" != "no image" ]]; then
  STATUS="error"
fi

# 2. 更新 JSON
NOW=\$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "\$PAYLOAD_FILE" <<JSON
{
  "mac_ip": "\$MAC_PRIVATE_IP",
  "public_ip": "\$MAC_PUBLIC_IP",
  "api_port": \$API_PORT,
  "ssh_port": \$SSH_PORT,
  "nx_port": \$NX_PORT,
  "ocr_test": "ok",
  "api_status": "\$STATUS",
  "updated_at": "\$NOW"
}
JSON

# 3. 推送到 VPS
curl -sk -X POST "\$VPS_URL" -H "Content-Type: application/json" -d "@\$PAYLOAD_FILE" >/dev/null 2>&1
EOF

chmod +x "$APP_DIR/healthcheck.sh"

### launchctl 配置健康检查

cat > /Library/LaunchDaemons/com.macapi.health.plist <<EOF
<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.macapi.health</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP_DIR/healthcheck.sh</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/health.out</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/health.err</string>
</dict>
</plist>
EOF

launchctl unload /Library/LaunchDaemons/com.macapi.health.plist 2>/dev/null || true
launchctl load /Library/LaunchDaemons/com.macapi.health.plist

echo "===================================================="
echo " CloudMac OCR API 部署完成"
echo " 内网 IP: $MAC_PRIVATE_IP"
echo " 公网 IP: $MAC_PUBLIC_IP"
echo " API 地址: http://127.0.0.1:$API_PORT/ocr"
echo " 自动注册到 VPS: $VPS_API_URL"
echo " 健康检查: 每 60 秒自动上报"
echo "===================================================="
