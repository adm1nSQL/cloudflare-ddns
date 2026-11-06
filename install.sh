
#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Cloudflare DDNS Interactive Installer
# ============================================================

DEFAULT_DIR="/opt/cloudflare-ddns"
APP_DIR="$DEFAULT_DIR"

SERVICE="cloudflare-ddns"
BIN_LINK="/usr/local/bin/cloudflare-ddns"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

if [[ -f "$SCRIPT_DIR/config.conf" ]]; then
    APP_DIR="$SCRIPT_DIR"
fi

TELEGRAM_ENABLED="false"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# -------------------- 基础函数 --------------------

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "请使用 root 用户执行"
        exit 1
    fi
}

pause() {
    echo
    read -r -p "按回车键返回菜单..." _
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_installed() {
    [[ -f "$APP_DIR/config.conf" &&
       -f "$APP_DIR/ddns.sh" &&
       -f "/etc/systemd/system/${SERVICE}.service" ]]
}

# -------------------- 系统信息 --------------------

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-unknown}"
    else
        OS_ID="unknown"
        OS_NAME="unknown"
    fi

    echo "操作系统：$OS_NAME"
    echo "系统架构：$(uname -m)"
}

check_systemd() {
    if ! check_command systemctl || [[ ! -d /run/systemd/system ]]; then
        echo "当前环境没有运行 systemd，无法配置自动定时任务"
        return 1
    fi

    return 0
}

# -------------------- 安装软件包 --------------------

install_package() {
    local package="$1"

    case "$OS_ID" in
        debian|ubuntu|linuxmint|kali|raspbian)
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
            ;;
        centos|rhel|rocky|almalinux|ol)
            if check_command dnf; then
                dnf install -y "$package"
            else
                yum install -y "$package"
            fi
            ;;
        fedora)
            dnf install -y "$package"
            ;;
        *)
            echo "当前系统不支持自动安装软件包：$OS_ID"
            return 1
            ;;
    esac
}

# -------------------- 环境检测和自动修复 --------------------

environment_check() {
    require_root

    echo
    echo "========== 环境检测与自动修复 =========="

    detect_os

    check_systemd || return 1

    if (( BASH_VERSINFO[0] < 4 )); then
        echo "需要 Bash 4 或更高版本"
        return 1
    fi

    local -a missing=()
    local cmd

    local -a required=(
        bash
        curl
        jq
        flock
        base64
        date
        readlink
        stat
        tr
        tail
    )

    echo
    echo "检查必要组件"

    for cmd in "${required[@]}"; do
        if check_command "$cmd"; then
            echo "[正常] $cmd"
        else
            echo "[缺失] $cmd"
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        echo
        echo "发现缺失组件，开始自动补齐"

        case "$OS_ID" in
            debian|ubuntu|linuxmint|kali|raspbian)
                apt-get update
                ;;
            centos|rhel|rocky|almalinux|ol)
                if check_command dnf; then
                    dnf makecache
                else
                    yum makecache
                fi
                ;;
            fedora)
                dnf makecache
                ;;
            *)
                echo "不支持当前系统的软件包管理方式"
                return 1
                ;;
        esac

        for cmd in "${missing[@]}"; do
            case "$cmd" in
                bash)
                    install_package bash
                    ;;
                curl)
                    install_package curl
                    ;;
                jq)
                    install_package jq
                    ;;
                flock)
                    install_package util-linux
                    ;;
                base64|date|tr)
                    install_package coreutils
                    ;;
                readlink|stat)
                    install_package coreutils
                    ;;
                tail)
                    install_package coreutils
                    ;;
            esac
        done
    fi

    echo
    echo "重新检查依赖"

    for cmd in "${required[@]}"; do
        if ! check_command "$cmd"; then
            echo "依赖安装失败：$cmd"
            return 1
        fi
    done

    mkdir -p "$APP_DIR/data" "$APP_DIR/logs"

    chmod 700 "$APP_DIR" "$APP_DIR/data" "$APP_DIR/logs"

    touch "$APP_DIR/logs/ddns.log"
    chmod 600 "$APP_DIR/logs/ddns.log"

    echo
    echo "检查公网连接"

    if curl -4 -fsS \
        --connect-timeout 8 \
        --max-time 15 \
        https://api.ipify.org >/dev/null; then
        echo "[正常] 公网 IP 查询服务可访问"
    else
        echo "[警告] 公网 IP 查询服务暂时无法访问"
    fi

    if curl -fsS \
        --connect-timeout 8 \
        --max-time 15 \
        -o /dev/null \
        https://api.cloudflare.com/client/v4; then
        echo "[正常] Cloudflare API 网络连接正常"
    else
        echo "[警告] Cloudflare API 暂时无法连接"
    fi

    echo
    echo "环境检测通过"
}

# -------------------- 写入配置文件 --------------------

write_config() {
    local zone="$1"
    local token="$2"
    local proxied="$3"
    local telegram_enabled="$4"
    local telegram_token="$5"
    local telegram_chat_id="$6"

    local token_escaped
    local telegram_token_escaped
    local telegram_chat_id_escaped
    local item

    printf -v token_escaped '%q' "$token"
    printf -v telegram_token_escaped '%q' "$telegram_token"
    printf -v telegram_chat_id_escaped '%q' "$telegram_chat_id"

    {
        printf 'CF_ZONE_NAME=%q\n' "$zone"
        printf 'CF_API_TOKEN=%s\n' "$token_escaped"
        printf 'CF_PROXIED=%q\n' "$proxied"

        printf 'IP_CHECK_URL=%q\n' "https://api.ipify.org"
        printf 'IP_CHECK_BACKUP_URL=%q\n' "https://ipv4.icanhazip.com"

        printf 'CF_DOMAINS=('

        for item in "${DOMAINS[@]}"; do
            printf ' %q' "$item"
        done

        printf ' )\n'

        printf 'TELEGRAM_ENABLED=%q\n' "$telegram_enabled"
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$telegram_token_escaped"
        printf 'TELEGRAM_CHAT_ID=%s\n' "$telegram_chat_id_escaped"

    } > "$APP_DIR/config.conf"

    chmod 600 "$APP_DIR/config.conf"
}

# -------------------- Telegram 配置向导 --------------------

telegram_wizard() {
    local choice

    echo
    echo "========== Telegram 通知配置 =========="
    echo "1. 启用 Telegram 通知"
    echo "2. 暂不启用 Telegram 通知"
    echo

    read -r -p "请选择 [1-2]: " choice

    if [[ "$choice" == "1" ]]; then
        echo
        echo "请先通过 Telegram BotFather 创建机器人"
        echo "然后向机器人发送 /start"
        echo

        read -r -s -p "请输入 Telegram Bot Token: " TELEGRAM_BOT_TOKEN
        echo

        if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
            echo "Token 不能为空，Telegram 通知将关闭"
            TELEGRAM_ENABLED="false"
            TELEGRAM_BOT_TOKEN=""
            TELEGRAM_CHAT_ID=""
            return
        fi

        read -r -p "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID

        if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
            echo "Chat ID 不能为空，Telegram 通知将关闭"
            TELEGRAM_ENABLED="false"
            TELEGRAM_BOT_TOKEN=""
            TELEGRAM_CHAT_ID=""
            return
        fi

        TELEGRAM_ENABLED="true"
    else
        TELEGRAM_ENABLED="false"
        TELEGRAM_BOT_TOKEN=""
        TELEGRAM_CHAT_ID=""
    fi
}

# -------------------- Cloudflare 配置向导 --------------------

configure_app() {
    local zone
    local token
    local proxied
    local domain
    local confirm

    DOMAINS=()

    echo
    echo "========== Cloudflare 配置 =========="

    read -r -p "Cloudflare Zone 主域名 [koooa.cc]: " zone
    zone="${zone:-koooa.cc}"

    if ! valid_domain "$zone"; then
        echo "Zone 域名格式不正确"
        return 1
    fi

    echo
    echo "逐个输入需要同步的完整域名"
    echo "直接回车结束输入"
    echo

    while true; do
        read -r -p "DDNS 域名: " domain

        [[ -z "$domain" ]] && break

        if ! valid_domain "$domain"; then
            echo "域名格式不正确"
            continue
        fi

        if [[ "$domain" != "$zone" && "$domain" != *".$zone" ]]; then
            echo "域名不属于当前 Zone：$zone"
            continue
        fi

        local duplicated=0
        local item

        for item in "${DOMAINS[@]}"; do
            if [[ "$item" == "$domain" ]]; then
                duplicated=1
                break
            fi
        done

        if (( duplicated )); then
            echo "该域名已经添加"
            continue
        fi

        DOMAINS+=("$domain")
        echo "已添加：$domain"
    done

    if (( ${#DOMAINS[@]} == 0 )); then
        echo "至少需要配置一个域名"
        return 1
    fi

    echo
    echo "Cloudflare Token 需要以下权限"
    echo "Zone Read"
    echo "DNS Edit"
    echo

    # 修复：使用局部变量 token，隐藏输入并支持粘贴
    read -r -s -p "请输入 Cloudflare API Token: " token
    echo

    if [[ -z "$token" ]]; then
        echo "Token 不能为空"
        return 1
    fi

    read -r -p "是否启用 Cloudflare 代理？(y/N): " proxied

    if [[ "$proxied" =~ ^[Yy]$ ]]; then
        proxied="true"
    else
        proxied="false"
    fi

    TELEGRAM_ENABLED="false"
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""

    telegram_wizard

    echo
    echo "========== 配置确认 =========="
    echo "Zone：$zone"
    printf '域名：\n'
    printf '  - %s\n' "${DOMAINS[@]}"
    echo "Cloudflare 代理：$proxied"

    if [[ "$TELEGRAM_ENABLED" == "true" ]]; then
        echo "Telegram 通知：已启用"
    else
        echo "Telegram 通知：未启用"
    fi

    read -r -p "确认保存配置？(Y/n): " confirm

    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        unset token
        echo "已取消"
        return 1
    fi

    write_config \
        "$zone" \
        "$token" \
        "$proxied" \
        "$TELEGRAM_ENABLED" \
        "$TELEGRAM_BOT_TOKEN" \
        "$TELEGRAM_CHAT_ID"

    unset token

    rm -f "$APP_DIR/data/last_ip"
    rm -f "$APP_DIR/data/last_failure_notice"

    echo "配置保存成功"
}

# -------------------- 复制程序文件 --------------------

install_files() {
    require_root

    if [[ ! -f "$SCRIPT_DIR/ddns.sh" ]]; then
        echo "没有找到同目录下的 ddns.sh"
        return 1
    fi

    mkdir -p "$APP_DIR/data" "$APP_DIR/logs"

    if [[ "$SCRIPT_DIR/ddns.sh" != "$APP_DIR/ddns.sh" ]]; then
        install -m 755 "$SCRIPT_DIR/ddns.sh" "$APP_DIR/ddns.sh"
    fi

    if [[ "$SCRIPT_PATH" != "$APP_DIR/install.sh" ]]; then
        install -m 700 "$SCRIPT_PATH" "$APP_DIR/install.sh"
    fi

    chmod 700 "$APP_DIR"
    chmod 755 "$APP_DIR/ddns.sh"
    chmod 700 "$APP_DIR/install.sh"

    touch "$APP_DIR/logs/ddns.log"
    chmod 600 "$APP_DIR/logs/ddns.log"
}

# -------------------- 安装 systemd --------------------

install_systemd() {
    require_root

    check_systemd || return 1

    if [[ "$APP_DIR" == *" "* ]]; then
        echo "安装目录不能包含空格"
        return 1
    fi

    cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Cloudflare DDNS IPv4 Update
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/bin/bash ${APP_DIR}/ddns.sh
EOF

    cat > "/etc/systemd/system/${SERVICE}.timer" <<EOF
[Unit]
Description=Cloudflare DDNS Timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=${SERVICE}.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload

    if ! systemctl enable --now "${SERVICE}.timer"; then
        echo "systemd 定时任务启动失败"
        journalctl -u "${SERVICE}.timer" -n 30 --no-pager || true
        return 1
    fi

    ln -sfn "$APP_DIR/install.sh" "$BIN_LINK"
}

# -------------------- 安装主流程 --------------------

install_app() {
    require_root

    echo
    echo "========== Cloudflare DDNS 安装 =========="

    local dir

    read -r -p "安装目录 [${DEFAULT_DIR}]: " dir
    APP_DIR="${dir:-$DEFAULT_DIR}"

    if [[ "$APP_DIR" != /* || "$APP_DIR" == *" "* ]]; then
        echo "请使用不包含空格的绝对路径"
        return 1
    fi

    environment_check || return 1

    if [[ -f "$APP_DIR/config.conf" ]]; then
        echo
        echo "检测到已有配置"
        read -r -p "重新配置并覆盖？(y/N): " overwrite

        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "已取消"
            return 0
        fi
    fi

    configure_app || return 1
    install_files || return 1
    install_systemd || return 1

    echo
    echo "=========================================="
    echo "DDNS 安装成功"
    echo "=========================================="
    echo "项目目录：$APP_DIR"
    echo "配置文件：$APP_DIR/config.conf"
    echo "核心程序：$APP_DIR/ddns.sh"
    echo "日志文件：$APP_DIR/logs/ddns.log"
    echo "管理命令：cloudflare-ddns"

    echo
    echo "正在执行首次同步"

    if systemctl start "${SERVICE}.service"; then
        echo "首次同步任务已执行"
    else
        echo "首次同步失败，请查看日志"
        journalctl -u "${SERVICE}.service" -n 30 --no-pager || true
    fi
}

# -------------------- Telegram 配置管理 --------------------

telegram_settings() {
    require_root

    if [[ ! -f "$APP_DIR/config.conf" ]]; then
        echo "请先安装并配置 DDNS"
        return
    fi

    source "$APP_DIR/config.conf"

    # 修复：恢复域名数组，防止 Telegram 设置保存时清空域名
    DOMAINS=("${CF_DOMAINS[@]}")

    echo
    echo "========== Telegram 通知管理 =========="

    if [[ "${TELEGRAM_ENABLED:-false}" == "true" ]]; then
        echo "当前状态：已启用"
        echo "Bot Token：已配置（隐藏）"
        echo "Chat ID：${TELEGRAM_CHAT_ID:-未配置}"
    else
        echo "当前状态：未启用"
    fi

    echo
    echo "1. 配置 / 修改 Telegram"
    echo "2. 关闭 Telegram 通知"
    echo "3. 发送测试消息"
    echo "0. 返回"
    echo

    local choice

    read -r -p "请选择 [0-3]: " choice

    case "$choice" in
        1)
            local new_token
            local new_chat_id

            read -r -s -p "请输入 Telegram Bot Token: " new_token
            echo

            if [[ -z "$new_token" ]]; then
                echo "Token 不能为空"
                return
            fi

            read -r -p "请输入 Telegram Chat ID: " new_chat_id

            if [[ -z "$new_chat_id" ]]; then
                echo "Chat ID 不能为空"
                return
            fi

            TELEGRAM_ENABLED="true"
            TELEGRAM_BOT_TOKEN="$new_token"
            TELEGRAM_CHAT_ID="$new_chat_id"

            write_config \
                "$CF_ZONE_NAME" \
                "$CF_API_TOKEN" \
                "$CF_PROXIED" \
                "$TELEGRAM_ENABLED" \
                "$TELEGRAM_BOT_TOKEN" \
                "$TELEGRAM_CHAT_ID"

            unset new_token

            echo "Telegram 配置已保存"
            ;;

        2)
            TELEGRAM_ENABLED="false"
            TELEGRAM_BOT_TOKEN=""
            TELEGRAM_CHAT_ID=""

            write_config \
                "$CF_ZONE_NAME" \
                "$CF_API_TOKEN" \
                "$CF_PROXIED" \
                "$TELEGRAM_ENABLED" \
                "$TELEGRAM_BOT_TOKEN" \
                "$TELEGRAM_CHAT_ID"

            echo "Telegram 通知已关闭"
            ;;

        3)
            if [[ "${TELEGRAM_ENABLED:-false}" != "true" ]]; then
                echo "请先配置并启用 Telegram"
                return
            fi

            local response
            local server_name

            server_name="$(hostname)"

            response="$(
                curl -fsS \
                    --connect-timeout 8 \
                    --max-time 15 \
                    -X POST \
                    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                    --data-urlencode "parse_mode=HTML" \
                    --data-urlencode "text=✅ <b>Cloudflare DDNS Telegram 测试成功</b>

服务器：<code>${server_name}</code>" \
                    2>/dev/null
            )" || {
                echo "发送失败，请检查 Token、Chat ID 和网络"
                return
            }

            if jq -e '.ok == true' <<< "$response" >/dev/null; then
                echo "测试消息发送成功，请检查 Telegram"
            else
                echo "Telegram API 返回错误："
                jq -r '.description // "未知错误"' <<< "$response"
            fi
            ;;

        0)
            return
            ;;

        *)
            echo "无效选项"
            ;;
    esac
}

# -------------------- 查看状态 --------------------

show_status() {
    require_root

    echo
    echo "========== DDNS 状态 =========="

    if ! is_installed; then
        echo "尚未安装"
        return
    fi

    systemctl status "${SERVICE}.timer" --no-pager || true

    echo
    echo "========== 定时器 =========="

    systemctl list-timers "${SERVICE}.timer" --no-pager || true

    echo
    echo "========== 上次成功同步 IP =========="

    if [[ -f "$APP_DIR/data/last_ip" ]]; then
        cat "$APP_DIR/data/last_ip"
    else
        echo "尚未成功同步"
    fi

    echo
    echo "========== 当前配置 =========="

    source "$APP_DIR/config.conf"

    echo "Zone：$CF_ZONE_NAME"
    printf '域名：\n'
    printf '  - %s\n' "${CF_DOMAINS[@]}"
    echo "Cloudflare 代理：$CF_PROXIED"

    if [[ "${TELEGRAM_ENABLED:-false}" == "true" ]]; then
        echo "Telegram 通知：已启用"
    else
        echo "Telegram 通知：未启用"
    fi
}

# -------------------- 手动检查 --------------------

manual_check() {
    require_root

    if ! is_installed; then
        echo "请先安装 DDNS"
        return
    fi

    echo "正在执行 DDNS 检查"

    if systemctl start "${SERVICE}.service"; then
        echo "检查任务执行完成"
    else
        echo "检查任务执行失败"
    fi

    journalctl -u "${SERVICE}.service" -n 30 --no-pager || true
}

# -------------------- 实时日志 --------------------

show_logs() {
    require_root

    if [[ ! -f "$APP_DIR/logs/ddns.log" ]]; then
        echo "日志文件不存在"
        return
    fi

    tail -n 100 -f "$APP_DIR/logs/ddns.log"
}

# -------------------- 重启服务 --------------------

restart_service() {
    require_root

    if ! is_installed; then
        echo "请先安装"
        return
    fi

    systemctl daemon-reload

    if systemctl enable --now "${SERVICE}.timer"; then
        systemctl restart "${SERVICE}.timer"
        echo "DDNS 定时任务已重启"
    else
        echo "DDNS 定时任务启动失败"
        journalctl -u "${SERVICE}.timer" -n 30 --no-pager || true
    fi
}

# -------------------- 停止服务 --------------------

stop_service() {
    require_root

    systemctl disable --now "${SERVICE}.timer" 2>/dev/null || true
    systemctl stop "${SERVICE}.service" 2>/dev/null || true

    echo "DDNS 定时任务已停止"
}

# -------------------- 编辑配置 --------------------

edit_config() {
    require_root

    if [[ ! -f "$APP_DIR/config.conf" ]]; then
        echo "配置文件不存在"
        return
    fi

    if check_command nano; then
        nano "$APP_DIR/config.conf"
    elif check_command vi; then
        vi "$APP_DIR/config.conf"
    else
        echo "没有找到 nano 或 vi"
        return
    fi

    chmod 600 "$APP_DIR/config.conf"

    echo "配置已保存"
    echo "修改域名后请删除 data/last_ip 并执行一次检查"
}

# -------------------- 卸载 --------------------

uninstall_app() {
    require_root

    echo
    echo "========== 卸载方式 =========="
    echo "1. 卸载服务，保留程序和配置"
    echo "2. 完全卸载，删除所有项目文件"
    echo "0. 返回"
    echo

    local choice

    read -r -p "请选择 [0-2]: " choice

    case "$choice" in
        1|2)
            read -r -p "确定卸载？(y/N): " confirm

            [[ "$confirm" =~ ^[Yy]$ ]] || return

            systemctl disable --now "${SERVICE}.timer" 2>/dev/null || true
            systemctl stop "${SERVICE}.service" 2>/dev/null || true

            rm -f "/etc/systemd/system/${SERVICE}.service"
            rm -f "/etc/systemd/system/${SERVICE}.timer"
            rm -f "$BIN_LINK"

            systemctl daemon-reload
            systemctl reset-failed

            if [[ "$choice" == "2" ]]; then
                rm -rf "$APP_DIR"
                echo "项目目录已删除"
            else
                echo "项目文件已保留：$APP_DIR"
            fi

            echo "卸载完成"
            ;;

        0)
            return
            ;;

        *)
            echo "无效选项"
            ;;
    esac
}

# -------------------- 管理菜单 --------------------

main_menu() {
    require_root

    while true; do
        clear 2>/dev/null || true

        echo
        echo "=============================================="
        echo "          Cloudflare DDNS 管理面板"
        echo "=============================================="

        echo "项目目录：$APP_DIR"

        if is_installed; then
            echo "安装状态：已安装"

            if systemctl is-active --quiet "${SERVICE}.timer"; then
                echo "定时任务：运行中"
            else
                echo "定时任务：已停止"
            fi
        else
            echo "安装状态：未安装"
        fi

        echo
        echo "  1. 安装 / 重新配置 DDNS"
        echo "  2. 查看运行状态"
        echo "  3. 立即执行一次 DNS 检查"
        echo "  4. 查看实时运行日志"
        echo "  5. 重启 DDNS 定时任务"
        echo "  6. 停止 DDNS 定时任务"
        echo "  7. 编辑配置文件"
        echo "  8. Telegram 通知设置 / 测试"
        echo "  9. 环境检测与自动修复"
        echo " 10. 卸载 DDNS"
        echo "  0. 退出"
        echo
        echo "=============================================="

        local choice

        read -r -p "请输入选项: " choice

        case "$choice" in
            1)
                install_app
                pause
                ;;
            2)
                show_status
                pause
                ;;
            3)
                manual_check
                pause
                ;;
            4)
                show_logs
                ;;
            5)
                restart_service
                pause
                ;;
            6)
                stop_service
                pause
                ;;
            7)
                edit_config
                pause
                ;;
            8)
                telegram_settings
                pause
                ;;
            9)
                environment_check
                pause
                ;;
            10)
                uninstall_app
                pause
                ;;
            0)
                echo "已退出"
                exit 0
                ;;
            *)
                echo "无效选项"
                sleep 1
                ;;
        esac
    done
}

main_menu
