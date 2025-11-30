sudo mkdir -p /root/gsprodep && cd /root/gsprodep
sudo tee auto_ssl_wpmap.sh >/dev/null <<'BASH'
# 已内置：创建/更新 NPM 反代 → 申请并绑定 SSL（兼容 NPM v2.13.5）
# → 写入 /etc/hosts → WP 多站点加入 gsliberty.com → 重载 NPM
# 依赖：docker、curl、jq、dnsutils（会自动装）
set -euo pipefail
SERVER_IP="82.180.137.120"; ROOT_DOMAIN="hulin.pro"
ADMIN_EMAIL="gs@hulin.pro"; ADMIN_PASS="Gaomeilan862447#"
NPM_UI="http://127.0.0.1:81"; PORT_WP=8081
DOMAINS=(hulin.pro wp.hulin.pro ezglinns.com gsliberty.com hulin.bz dri.hulin.pro doc.hulin.pro coc.hulin.pro vnc.hulin.pro panel.hulin.pro npm.hulin.pro)
declare -A TARGET=(
  [hulin.pro]="http://127.0.0.1:${PORT_WP}"
  [wp.hulin.pro]="http://127.0.0.1:${PORT_WP}"
  [ezglinns.com]="http://127.0.0.1:${PORT_WP}"
  [gsliberty.com]="http://127.0.0.1:${PORT_WP}"
  [hulin.bz]="http://127.0.0.1:${PORT_WP}"
  [dri.hulin.pro]="http://127.0.0.1:8080"
  [doc.hulin.pro]="http://127.0.0.1:8083"
  [coc.hulin.pro]="http://127.0.0.1:9090"
  [vnc.hulin.pro]="http://127.0.0.1:6080"
  [panel.hulin.pro]="http://127.0.0.1:8812"
  [npm.hulin.pro]="http://127.0.0.1:81"
)
log(){ echo -e "\033[1;32m[$(date +'%H:%M:%S')] $*\033[0m"; }
warn(){ echo -e "\033[1;33m[$(date +'%H:%M:%S')] $*\033[0m"; }
die(){ echo -e "\033[1;31m[$(date +'%H:%M:%S')] $*\033[0m"; exit 1; }
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y jq curl dnsutils >/dev/null 2>&1 || true
command -v docker >/dev/null || die "docker 未安装"
docker ps --format '{{.Names}}' | grep -q '^npm$' || die "npm 容器未运行"
ss -tulpn | grep -q ":81 " || die "81端口未监听（NPM UI 不可达）"
log "DNS 检查"
bad=0; for d in "${DOMAINS[@]}"; do ip=$(dig +short A "$d" @1.1.1.1 | tail -n1 || true); if [[ "$ip" != "$SERVER_IP" ]]; then warn "未指向本机：$d -> $ip（应为 $SERVER_IP）"; bad=$((bad+1)); else log "OK：$d -> $ip"; fi; done
log "写入 /etc/hosts"
sed -i '/# gspro-domains BEGIN/,/# gspro-domains END/d' /etc/hosts
{ echo "# gspro-domains BEGIN"; for d in "${DOMAINS[@]}"; do echo "127.0.0.1 $d"; done; echo "# gspro-domains END"; } >> /etc/hosts
log "登录 NPM"
TOKEN=$(curl -sS -H "Content-Type: application/json" -X POST "${NPM_UI}/api/tokens" -d "{\"identity\":\"${ADMIN_EMAIL}\",\"secret\":\"${ADMIN_PASS}\"}" | jq -r ".token // empty") ; [[ -n "$TOKEN" ]] || die "NPM 登录失败"
AUTH="Authorization: Bearer ${TOKEN}"
HOSTS_JSON=$(curl -sS -H "$AUTH" "${NPM_UI}/api/nginx/proxy-hosts")
npm_find(){ echo "$HOSTS_JSON" | jq -r ".[] | select(.domain_names | index(\"$1\")!=null) | .id" | head -n1; }
for d in "${DOMAINS[@]}"; do
  t="${TARGET[$d]}"; s=$(sed -E 's#^(https?)://.*#\1#'<<<"$t"); h=$(sed -E 's#^https?://([^:/]+).*#\1#'<<<"$t"); p=$(sed -E 's#^https?://[^:]+:([0-9]+).*#\1#'<<<"$t"); [[ -z "$p" ]] && p=$([[ "$s" == "https" ]]&&echo 443||echo 80)
  hid=$(npm_find "$d" || true)
  payload=$(jq -n --arg d "$d" --arg s "$s" --arg h "$h" --argjson p "$p" '{"domain_names":[ $d ],"forward_scheme":$s,"forward_host":$h,"forward_port":$p,"caching_enabled":false,"block_exploits":true,"http2_support":true,"allow_websocket_upgrade":true,"ssl_forced":false}')
  if [[ -n "$hid" ]]; then log "更新 NPM：$d (ID=$hid) -> $s://$h:$p"; curl -sS -H "$AUTH" -H "Content-Type: application/json" -X PUT "${NPM_UI}/api/nginx/proxy-hosts/${hid}" -d "$payload" >/dev/null
  else log "创建 NPM：$d -> $s://$h:$p"; curl -sS -H "$AUTH" -H "Content-Type: application/json" -X POST "${NPM_UI}/api/nginx/proxy-hosts" -d "$payload" >/dev/null; fi
done
HOSTS_JSON=$(curl -sS -H "$AUTH" "${NPM_UI}/api/nginx/proxy-hosts")
for d in "${DOMAINS[@]}"; do
  hid=$(echo "$HOSTS_JSON" | jq -r ".[] | select(.domain_names | index(\"${d}\")!=null) | .id" | head -n1); [[ -z "$hid" ]] && { warn "缺少 Host：$d 跳过证书"; continue; }
  log "证书申请：$d"
  res=$(curl -sS -H "$AUTH" -H "Content-Type: application/json" -X POST "${NPM_UI}/api/nginx/certificates" -d "$(jq -n --arg d "$d" --arg e "$ADMIN_EMAIL" '{provider:"letsencrypt",domain_names:[$d],meta:{letsencrypt_email:$e,letsencrypt_agree:true,dns_challenge:false}}')")
  cid=$(echo "$res" | jq -r '.id // empty'); if [[ -z "$cid" ]]; then warn "证书失败：$res"; continue; fi
  upd=$(jq -n --argjson cid "$cid" '{certificate_id:$cid,ssl_forced:true,http2_support:true,hsts_enabled:true,hsts_subdomains:true}')
  curl -sS -H "$AUTH" -H "Content-Type: application/json" -X PUT "${NPM_UI}/api/nginx/proxy-hosts/${hid}" -d "$upd" >/dev/null
done
docker exec npm nginx -s reload >/dev/null 2>&1 || true
log "WordPress Multisite：并入 gsliberty.com"
WP=$(docker ps --format '{{.Names}}\t{{.Ports}}'|awk -F'\t' -v p=":${PORT_WP}->" '$2~p{print $1;exit}')
[[ -n "$WP" ]] || die "未找到 WP 容器(端口 ${PORT_WP})"
docker exec -i "$WP" bash -lc "
set -e; cd /var/www/html
command -v wp >/dev/null || { apt-get update && apt-get install -y curl less mariadb-client >/dev/null; curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; php wp-cli.phar --info >/dev/null && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp; }
grep -q MULTISITE wp-config.php || {
  wp config set WP_ALLOW_MULTISITE true --raw
  wp config set MULTISITE true --raw
  wp config set SUBDOMAIN_INSTALL true --raw
  wp config set DOMAIN_CURRENT_SITE '${ROOT_DOMAIN}'
  wp config set PATH_CURRENT_SITE '/'
  wp config set SITE_ID_CURRENT_SITE 1 --raw
  wp config set BLOG_ID_CURRENT_SITE 1 --raw
}
wp site list --fields=url | grep -q gsliberty || wp site create --slug=gsliberty --title='GSLiberty' --email='${ADMIN_EMAIL}' || true
bid=\$(wp site list --fields=blog_id,url | awk '/gsliberty/{print \$1}'|head -n1)
[ -n \"\$bid\" ] && wp site update \"\$bid\" --domain='gsliberty.com' --path=/
wp rewrite structure '/%postname%/' --hard
"
log "完成 ✅"
BASH
sudo chmod +x auto_ssl_wpmap.sh
sudo bash ./auto_ssl_wpmap.sh
