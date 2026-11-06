
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Cloudflare DDNS Core
# Telegram HTML notification
# ============================================================

BASE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="$BASE_DIR/config.conf"

DATA_DIR="$BASE_DIR/data"
LOG_DIR="$BASE_DIR/logs"

LOG_FILE="$LOG_DIR/ddns.log"
LAST_IP_FILE="$DATA_DIR/last_ip"
LOCK_FILE="$DATA_DIR/ddns.lock"
LAST_FAILURE_NOTICE="$DATA_DIR/last_failure_notice"

mkdir -p "$DATA_DIR" "$LOG_DIR"
chmod 700 "$BASE_DIR" "$DATA_DIR" "$LOG_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "配置文件不存在：$CONFIG_FILE"
    exit 1
fi

if [[ "$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo 000)" != "600" ]]; then
    chmod 600 "$CONFIG_FILE"
fi

source "$CONFIG_FILE"

: "${CF_API_TOKEN:?Cloudflare API Token 未配置}"
: "${CF_ZONE_NAME:?Cloudflare Zone 未配置}"
: "${IP_CHECK_URL:=https://api.ipify.org}"
: "${IP_CHECK_BACKUP_URL:=https://ipv4.icanhazip.com}"
: "${CF_PROXIED:=false}"
: "${TELEGRAM_ENABLED:=false}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"

if [[ ! "${CF_PROXIED}" =~ ^(true|false)$ ]]; then
    echo "CF_PROXIED 配置错误"
    exit 1
fi

if [[ "${#CF_DOMAINS[@]}" -eq 0 ]]; then
    echo "没有配置需要同步的域名"
    exit 1
fi

# -------------------- 日志 --------------------

log() {
    local message="$1"
    local size=0

    if [[ -f "$LOG_FILE" ]]; then
        size="$(stat -c '%s' "$LOG_FILE" 2>/dev/null || echo 0)"
    fi

    if (( size > 5242880 )); then
        mv -f "$LOG_FILE" "$LOG_FILE.1"
        chmod 600 "$LOG_FILE.1"
    fi

    printf '[%s] %s\n' "$(date '+%F %T')" "$message" | tee -a "$LOG_FILE"
}

# -------------------- HTML 转义 --------------------

html_escape() {
    local value="$1"

    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&#39;}"

    printf '%s' "$value"
}

# -------------------- Telegram 通知 --------------------

telegram_send() {
    local message="$1"
    local response

    [[ "$TELEGRAM_ENABLED" == "true" ]] || return 0
    [[ -n "$TELEGRAM_BOT_TOKEN" ]] || return 0
    [[ -n "$TELEGRAM_CHAT_ID" ]] || return 0

    response="$(
        curl -fsS \
            --connect-timeout 8 \
            --max-time 15 \
            -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${message}" \
            --data-urlencode "parse_mode=HTML" \
            --data-urlencode "disable_web_page_preview=true" \
            2>/dev/null
    )" || {
        log "Telegram 通知发送失败"
        return 1
    }

    if ! jq -e '.ok == true' <<< "$response" >/dev/null 2>&1; then
        log "Telegram API 返回错误，通知未发送"
        return 1
    fi

    log "Telegram 通知发送成功"
    return 0
}

# -------------------- 异常通知限频 --------------------

notify_failure() {
    local message="$1"
    local now
    local last=0

    [[ "$TELEGRAM_ENABLED" == "true" ]] || return 0

    now="$(date +%s)"

    if [[ -f "$LAST_FAILURE_NOTICE" ]]; then
        last="$(cat "$LAST_FAILURE_NOTICE" 2>/dev/null || echo 0)"
    fi

    if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < 1800 )); then
        log "异常通知处于 30 分钟限频期，跳过本次通知"
        return 0
    fi

    # 先记录发送时间，避免 Telegram 网络异常时每分钟重试刷屏
    printf '%s\n' "$now" > "$LAST_FAILURE_NOTICE"
    chmod 600 "$LAST_FAILURE_NOTICE"

    telegram_send "$message" || true
}

# -------------------- 防止并发 --------------------

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "已有 DDNS 任务正在执行，本次跳过"
    exit 0
fi

# -------------------- IPv4 校验 --------------------

valid_ipv4() {
    local ip="$1"
    local -a parts
    local part

    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    IFS='.' read -r -a parts <<< "$ip"

    for part in "${parts[@]}"; do
        (( 10#$part <= 255 )) || return 1
    done

    return 0
}

# -------------------- 获取公网 IPv4 --------------------

get_public_ip() {
    local ip=""

    ip="$(
        curl -4 -fsS \
            --connect-timeout 8 \
            --max-time 15 \
            "$IP_CHECK_URL" 2>/dev/null |
            tr -d '[:space:]' || true
    )"

    if ! valid_ipv4 "$ip"; then
        ip="$(
            curl -4 -fsS \
                --connect-timeout 8 \
                --max-time 15 \
                "$IP_CHECK_BACKUP_URL" 2>/dev/null |
                tr -d '[:space:]' || true
        )"
    fi

    valid_ipv4 "$ip" || return 1

    printf '%s\n' "$ip"
}

# -------------------- Cloudflare API --------------------

cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local -a args=(
        -fsS
        --connect-timeout 10
        --max-time 30
        -X "$method"
        "https://api.cloudflare.com/client/v4${endpoint}"
        -H "Authorization: Bearer ${CF_API_TOKEN}"
        -H "Content-Type: application/json"
    )

    if [[ -n "$data" ]]; then
        args+=(--data "$data")
    fi

    curl "${args[@]}"
}

check_cf_response() {
    local response="$1"

    if ! jq -e '.success == true' <<< "$response" >/dev/null 2>&1; then
        jq -r '.errors[]? | "\(.code // "") \(.message // "")"' \
            <<< "$response" >&2 || true

        return 1
    fi

    return 0
}

# -------------------- 获取 Zone ID --------------------

get_zone_id() {
    local response
    local zone_id
    local encoded_zone

    encoded_zone="$(
        jq -rn --arg value "$CF_ZONE_NAME" '$value | @uri'
    )"

    response="$(
        cf_api GET "/zones?name=${encoded_zone}"
    )" || return 1

    check_cf_response "$response" || return 1

    zone_id="$(jq -r '.result[0].id // empty' <<< "$response")"

    [[ -n "$zone_id" ]] || return 1

    printf '%s\n' "$zone_id"
}

# -------------------- 同步单个域名 --------------------

sync_domain() {
    local zone_id="$1"
    local domain="$2"
    local public_ip="$3"

    local response
    local record_count
    local record_id=""
    local current_ip=""
    local encoded_domain
    local payload
    local duplicate_id

    local -a duplicate_ids=()

    log "正在检查域名：$domain"

    encoded_domain="$(
        jq -rn --arg value "$domain" '$value | @uri'
    )"

    response="$(
        cf_api GET \
            "/zones/${zone_id}/dns_records?type=A&name=${encoded_domain}&per_page=100"
    )" || {
        log "查询 DNS 失败：$domain"
        return 1
    }

    check_cf_response "$response" || return 1

    record_count="$(jq '.result | length' <<< "$response")"

    if (( record_count > 0 )); then
        record_id="$(jq -r '.result[0].id' <<< "$response")"
        current_ip="$(jq -r '.result[0].content' <<< "$response")"

        mapfile -t duplicate_ids < <(
            jq -r '.result[1:][]?.id' <<< "$response"
        )
    fi

    payload="$(
        jq -n \
            --arg name "$domain" \
            --arg ip "$public_ip" \
            --argjson proxied "$CF_PROXIED" \
            '{
                type: "A",
                name: $name,
                content: $ip,
                ttl: 1,
                proxied: $proxied
            }'
    )"

    if [[ -z "$record_id" ]]; then
        log "记录不存在，准备创建：$domain"

        response="$(
            cf_api POST \
                "/zones/${zone_id}/dns_records" \
                "$payload"
        )" || {
            log "创建失败：$domain"
            return 1
        }

        check_cf_response "$response" || return 1

        log "创建成功：$domain -> $public_ip"

    elif [[ "$current_ip" != "$public_ip" ]]; then
        log "IP 发生变化：$domain"
        log "旧 IP：$current_ip"
        log "新 IP：$public_ip"

        response="$(
            cf_api PUT \
                "/zones/${zone_id}/dns_records/${record_id}" \
                "$payload"
        )" || {
            log "更新失败：$domain"
            return 1
        }

        check_cf_response "$response" || return 1

        log "更新成功：$domain -> $public_ip"

    else
        log "IP 正确，无需更新：$domain"
    fi

    # 清理同名重复 A 记录
    for duplicate_id in "${duplicate_ids[@]}"; do
        [[ -z "$duplicate_id" ]] && continue

        response="$(
            cf_api DELETE \
                "/zones/${zone_id}/dns_records/${duplicate_id}"
        )" || {
            log "删除重复记录失败：$duplicate_id"
            return 1
        }

        check_cf_response "$response" || return 1

        log "已删除重复记录：$duplicate_id"
    done

    return 0
}

# -------------------- 主逻辑 --------------------

do_check() {
    log "=========================================="
    log "开始检测本机公网 IPv4"

    local public_ip

    public_ip="$(get_public_ip)" || {
        log "获取公网 IPv4 失败"

        local server_name
        server_name="$(html_escape "$(hostname)")"

        notify_failure \
            "⚠️ <b>Cloudflare DDNS 异常</b>

服务器：<code>${server_name}</code>
原因：获取公网 IPv4 失败"

        return 1
    }

    log "当前公网 IPv4：$public_ip"

    local last_ip=""

    if [[ -f "$LAST_IP_FILE" ]]; then
        last_ip="$(cat "$LAST_IP_FILE" 2>/dev/null || true)"
    fi

    if [[ "$public_ip" == "$last_ip" ]]; then
        log "公网 IP 未发生变化，跳过 Cloudflare API"
        return 0
    fi

    log "检测到公网 IP 变化：${last_ip:-首次检测} -> $public_ip"

    local zone_id

    zone_id="$(get_zone_id)" || {
        log "获取 Cloudflare Zone ID 失败"

        local server_name
        server_name="$(html_escape "$(hostname)")"

        notify_failure \
            "⚠️ <b>Cloudflare DDNS 异常</b>

服务器：<code>${server_name}</code>
原因：获取 Cloudflare Zone ID 失败
当前 IP：<code>${public_ip}</code>"

        return 1
    }

    local failed=0
    local domain

    for domain in "${CF_DOMAINS[@]}"; do
        if ! sync_domain "$zone_id" "$domain" "$public_ip"; then
            log "域名同步失败：$domain"
            failed=1
        fi
    done

    if (( failed != 0 )); then
        log "部分域名同步失败，下次继续重试"

        local server_name
        server_name="$(html_escape "$(hostname)")"

        notify_failure \
            "⚠️ <b>Cloudflare DDNS 同步失败</b>

服务器：<code>${server_name}</code>
当前 IP：<code>${public_ip}</code>
请检查服务器运行日志"

        return 1
    fi

    printf '%s\n' "$public_ip" > "$LAST_IP_FILE"
    chmod 600 "$LAST_IP_FILE"

    rm -f "$LAST_FAILURE_NOTICE"

    log "全部域名同步成功"
    log "当前公网 IPv4：$public_ip"

    local domain_list=""
    local safe_domain

    for domain in "${CF_DOMAINS[@]}"; do
        safe_domain="$(html_escape "$domain")"
        domain_list+="<code>${safe_domain}</code>"$'\n'
    done

    local server_name
    server_name="$(html_escape "$(hostname)")"

    telegram_send \
        "✅ <b>Cloudflare DDNS 同步成功</b>

服务器：<code>${server_name}</code>
公网 IPv4：<code>${public_ip}</code>

同步域名：
${domain_list}" || true

    log "本次检查结束"
}

do_check
