NPM_API="http://127.0.0.1:81/api"
NPM_USER="Hulin"
NPM_PASS="Gaomeilan862447#"
ADMIN_EMAIL="gs@hulin.pro"
SERVER_IP="$(hostname -I | awk '{print $1}')"

safe_json() {
    echo "$1" | jq -e . >/dev/null 2>&1 && echo "$1" || echo "{}"
}

DOMAINS_ALL=(
"hulin.pro"
"wp.hulin.pro"
"dri.hulin.pro"
"doc.hulin.pro"
"npm.hulin.pro"
"vnc.hulin.pro"
"coc.hulin.pro"
"ezglinns.com"
)

declare -A TARGET_MAP=(
["hulin.pro"]="http://172.17.0.1:9080"
["wp.hulin.pro"]="http://172.17.0.1:9080"
["ezglinns.com"]="http://172.17.0.1:9080"
["dri.hulin.pro"]="http://172.17.0.1:9000"
["doc.hulin.pro"]="http://172.17.0.1:9980"
["npm.hulin.pro"]="http://127.0.0.1:81"
["vnc.hulin.pro"]="http://127.0.0.1:6080"
["coc.hulin.pro"]="http://127.0.0.1:9090"
)

npm_login() {
    local payload resp
    payload="{\"identity\":\"${NPM_USER}\",\"secret\":\"${NPM_PASS}\"}"
    resp=$(curl -sS -H "Content-Type: application/json" -X POST "${NPM_API}/tokens" -d "$payload")
    resp=$(safe_json "$resp")
    TOKEN=$(echo "$resp" | jq -r '.token // empty')
    [[ -z "$TOKEN" || "$TOKEN" == "null" ]] && return 1 || return 0
}

npm_get_proxy_id() {
    local d="$1" resp
    resp=$(curl -sS -H "Authorization: Bearer $TOKEN" "${NPM_API}/nginx/proxy-hosts")
    resp=$(safe_json "$resp")
    echo "$resp" | jq ".[] | select(.domain_names[]==\"$d\") | .id" | head -n1
}

npm_create_proxy() {
    local d="$1" t="$2"
    local host fh fp payload

    host="${t#http://}"
    fh="${host%:*}"
    fp="${host##*:}"

    payload=$(jq -nc \
        --argjson dn "[\"$d\"]" \
        --arg fh "$fh" \
        --argjson fp "$fp" \
        '{domain_names:$dn,forward_scheme:"http",forward_host:$fh,forward_port:($fp|tonumber),access_list_id:0,certificate_id:0,ssl_forced:false}')

    curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
         -X POST "${NPM_API}/nginx/proxy-hosts" -d "$payload" >/dev/null
}

npm_ssl_retry() {
    local domain="$1"
    local payload resp cert_id

    payload=$(jq -nc \
        --argjson dn "[\"$domain\"]" \
        --arg em "$ADMIN_EMAIL" \
        '{domain_names:$dn,email:$em,provider:"letsencrypt",challenge:"http",agree_tos:true}')

    for try in {1..20}; do
        resp=$(curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
            -X POST "${NPM_API}/certificates" -d "$payload")

        resp=$(safe_json "$resp")
        cert_id=$(echo "$resp" | jq -r '.id // empty')

        if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
            echo "$cert_id"
            return 0
        fi

        sleep 10
    done

    return 1
}

npm_bind_ssl() {
    local pid="$1" cid="$2"
    local payload

    payload=$(jq -nc --argjson cid "$cid" \
        '{certificate_id:$cid,ssl_forced:true,http2_support:true,hsts_enabled:false,hsts_subdomains:false}')

    curl -sS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
         -X PUT "${NPM_API}/nginx/proxy-hosts/${pid}" -d "$payload" >/dev/null
}

npm_login || { echo "NPM LOGIN FAILED"; exit 1; }

for domain in "${DOMAINS_ALL[@]}"; do

    resolved_ip=$(dig +short "$domain" | head -n1)
    [[ "$resolved_ip" != "$SERVER_IP" ]] && continue

    target="${TARGET_MAP[$domain]}"

    npm_create_proxy "$domain" "$target"
    sleep 1

    pid=$(npm_get_proxy_id "$domain")
    [[ -z "$pid" || "$pid" == "null" ]] && continue

    cid=$(npm_ssl_retry "$domain")
    [[ -z "$cid" || "$cid" == "null" ]] && continue

    npm_bind_ssl "$pid" "$cid"
done

docker exec npm nginx -s reload || true
