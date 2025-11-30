#!/usr/bin/env bash
set -e

echo "================ GitHub 安全上传工具 ================="
echo "⚠️ Token 不会被保存，不会写入文件，不会上传到服务器"
echo

read -rp "GitHub 用户名: " GH_USER
read -rp "仓库名（例如 gsprodep）: " GH_REPO
read -rp "要上传的脚本路径（例如 /root/gsprodep.sh）: " FILE_PATH
read -rp "提交说明（commit message）: " COMMIT_MSG
echo
read -rs -p "请输入 GitHub Token（不会保存）: " GH_TOKEN
echo

TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"

git clone "https://github.com/$GH_USER/$GH_REPO.git" repo
cd repo

cp "$FILE_PATH" ./ || { echo "❌ 找不到文件"; exit 1; }

git add .
git commit -m "$COMMIT_MSG"

echo
echo "▶️ 正在 Push 到 GitHub（使用你的 Token）..."
git push "https://$GH_USER:$GH_TOKEN@github.com/$GH_USER/$GH_REPO.git" HEAD:main

echo
echo "✅ 上传完成！"
echo "仓库地址：https://github.com/$GH_USER/$GH_REPO"
