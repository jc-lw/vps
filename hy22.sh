#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Hysteria 2 链式落地 + 自动故障切换
#
# 正常状态：客户端 -> 1号 HY2 -> 2号 SOCKS5:3333 -> 台湾家宽
# 故障状态：2号 SOCKS5 不可用时，自动切换为 1号服务器本地 IPv4 出口
# 恢复状态：每 60 秒检测一次，检测到 2号 SOCKS5 恢复后立即切回
#
# 注意：切换出口时会重启一次 hy2-custom，已有连接会短暂重连。
# ============================================================

# -------------------- 可修改参数 --------------------
PASSWORD="e3a5bb40be52de65"
TARGET_PORT="2328"
RELAY_HOST="hk1.cebaoge.me"
RELAY_PORT="3333"
CHECK_INTERVAL="60"
SUB_PORT="28180"

# 只在 2号 SOCKS5 的真实出口为台湾 IPv4 时使用它。
# 设为 0 时只检查 SOCKS5 是否能正常访问外网。
REQUIRE_TW="1"

# 保持你原脚本使用的 Hysteria 版本，避免无意改变运行行为。
HYSTERIA_VERSION="app/v2.2.4"
# ----------------------------------------------------

BASE_DIR="/etc/hy2-custom"
WWW_DIR="${BASE_DIR}/www"
CONFIG_FILE="${BASE_DIR}/config.yaml"
ACL_FILE="${BASE_DIR}/active.acl"
STATE_FILE="${BASE_DIR}/egress.mode"
FAILOVER_ENV="${BASE_DIR}/failover.conf"
BIN_PATH="/usr/local/bin/hy2-custom"
CHECK_SCRIPT="/usr/local/sbin/hy2-relay-check"
LOOP_SCRIPT="/usr/local/sbin/hy2-relay-monitor-loop"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fatal() {
    log "错误: $*"
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    fatal "必须使用 root 运行"
fi

install_dependencies() {
    log "安装运行依赖..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            ca-certificates curl openssl wget python3 util-linux
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache ca-certificates curl openssl wget python3 util-linux
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates curl openssl wget python3 util-linux
    elif command -v yum >/dev/null 2>&1; then
        yum install -y ca-certificates curl openssl wget python3 util-linux
    else
        fatal "不支持的包管理器"
    fi
}

download_hysteria() {
    local arch url version_path
    arch="$(uname -m)"
    version_path="${HYSTERIA_VERSION//\//%2F}"

    case "$arch" in
        x86_64|amd64)
            url="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/${version_path}/hysteria-linux-amd64"
            ;;
        aarch64|arm64)
            url="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/${version_path}/hysteria-linux-arm64"
            ;;
        *)
            fatal "不支持的架构: $arch"
            ;;
    esac

    log "下载 Hysteria ${HYSTERIA_VERSION}..."
    rm -f "${BIN_PATH}.new"
    wget -qO "${BIN_PATH}.new" "$url"
    chmod 0755 "${BIN_PATH}.new"
    mv -f "${BIN_PATH}.new" "$BIN_PATH"
}

prepare_files() {
    mkdir -p "$BASE_DIR" "$WWW_DIR" /usr/local/sbin

    if [ ! -s "${BASE_DIR}/server.key" ] || [ ! -s "${BASE_DIR}/server.crt" ]; then
        log "生成自签名证书..."
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "${BASE_DIR}/server.key" \
            -out "${BASE_DIR}/server.crt" \
            -days 3650 \
            -subj "/CN=apps.apple.com" >/dev/null 2>&1
        chmod 0600 "${BASE_DIR}/server.key"
    fi

    cat > "$CONFIG_FILE" <<EOF_CONFIG
listen: :${TARGET_PORT}

tls:
  cert: ${BASE_DIR}/server.crt
  key: ${BASE_DIR}/server.key

auth:
  type: password
  password: "${PASSWORD}"

bandwidth:
  up: 10 gbps
  down: 10 gbps
ignoreClientBandwidth: true

masquerade:
  type: proxy
  proxy:
    url: https://apps.apple.com/
    rewriteHost: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432

# 两个静态出站：监控程序只切换 ACL，不改主配置。
outbounds:
  - name: Server2_Relay
    type: socks5
    socks5:
      addr: '${RELAY_HOST}:${RELAY_PORT}'

  - name: Direct_Local
    type: direct
    direct:
      mode: 4

acl:
  file: ${ACL_FILE}
EOF_CONFIG

    # 安装时先使用本地出口，随后由健康检查决定是否切换到 2号。
    if [ ! -s "$ACL_FILE" ]; then
        printf '%s\n' 'Direct_Local(all)' > "$ACL_FILE"
    fi
    if [ ! -s "$STATE_FILE" ]; then
        printf '%s\n' 'direct' > "$STATE_FILE"
    fi

    cat > "$FAILOVER_ENV" <<EOF_ENV
RELAY_HOST='${RELAY_HOST}'
RELAY_PORT='${RELAY_PORT}'
REQUIRE_TW='${REQUIRE_TW}'
ACL_FILE='${ACL_FILE}'
STATE_FILE='${STATE_FILE}'
EOF_ENV
    chmod 0600 "$FAILOVER_ENV"
}

write_check_script() {
    cat > "$CHECK_SCRIPT" <<'EOF_CHECK'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/hy2-custom/failover.conf"
[ -r "$ENV_FILE" ] || exit 1
# shellcheck disable=SC1090
. "$ENV_FILE"

LOCK_FILE="/run/hy2-relay-check.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

restart_hy2() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart hy2-custom.service
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service hy2-custom restart
    else
        return 1
    fi
}

hy2_is_active() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet hy2-custom.service
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service hy2-custom status >/dev/null 2>&1
    else
        return 1
    fi
}

check_relay() {
    local trace ip loc

    # 使用真实 SOCKS5 请求，而不是仅检查 TCP 端口。
    # 这样即使 3333 在监听，但 2号后端不能访问外网，也会判定为故障。
    trace="$(curl -4 -kfsS \
        --connect-timeout 4 \
        --max-time 10 \
        --proxy "socks5h://${RELAY_HOST}:${RELAY_PORT}" \
        https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)"

    ip="$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -n1)"
    loc="$(printf '%s\n' "$trace" | sed -n 's/^loc=//p' | head -n1)"

    # 必须取得 IPv4 地址。
    case "$ip" in
        *.*.*.*) ;;
        *) return 1 ;;
    esac

    if [ "${REQUIRE_TW:-1}" = "1" ] && [ "$loc" != "TW" ]; then
        return 1
    fi

    printf '%s|%s\n' "$ip" "$loc"
    return 0
}

apply_mode() {
    local desired="$1"
    local detail="${2:-}"
    local rule current tmp

    case "$desired" in
        relay)
            rule='Server2_Relay(all)'
            ;;
        direct)
            rule='Direct_Local(all)'
            ;;
        *)
            return 1
            ;;
    esac

    current="$(cat "$STATE_FILE" 2>/dev/null || true)"

    if [ "$current" = "$desired" ] && grep -Fxq "$rule" "$ACL_FILE" 2>/dev/null; then
        if ! hy2_is_active; then
            log "HY2 未运行，按 ${desired} 模式启动"
            restart_hy2
        fi
        exit 0
    fi

    tmp="${ACL_FILE}.tmp.$$"
    printf '%s\n' "$rule" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$ACL_FILE"
    printf '%s\n' "$desired" > "$STATE_FILE"

    if restart_hy2; then
        if [ "$desired" = "relay" ]; then
            log "已切换到 2号 SOCKS5 出口 ${RELAY_HOST}:${RELAY_PORT} (${detail})"
        else
            log "2号 SOCKS5 不可用，已切换到 1号本地 IPv4 出口"
        fi
        exit 0
    fi

    # 如果切到中转模式时重启失败，自动回滚为本地直连。
    if [ "$desired" = "relay" ]; then
        log "切换中转模式失败，回滚本地出口"
        printf '%s\n' 'Direct_Local(all)' > "$ACL_FILE"
        printf '%s\n' 'direct' > "$STATE_FILE"
        restart_hy2 || true
    fi
    exit 1
}

relay_detail="$(check_relay || true)"
if [ -n "$relay_detail" ]; then
    apply_mode relay "$relay_detail"
else
    apply_mode direct
fi
EOF_CHECK

    chmod 0755 "$CHECK_SCRIPT"

    cat > "$LOOP_SCRIPT" <<EOF_LOOP
#!/usr/bin/env sh
while :; do
    ${CHECK_SCRIPT} || true
    sleep ${CHECK_INTERVAL}
done
EOF_LOOP
    chmod 0755 "$LOOP_SCRIPT"
}

write_systemd_services() {
    cat > /etc/systemd/system/hy2-custom.service <<EOF_HY2_SERVICE
[Unit]
Description=Hysteria 2 Custom Server with SOCKS5 Failover
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}
ExecStart=${BIN_PATH} server -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_HY2_SERVICE

    cat > /etc/systemd/system/hy2-relay-monitor.service <<EOF_MONITOR_SERVICE
[Unit]
Description=Check Server2 SOCKS5 and switch Hysteria outbound
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${CHECK_SCRIPT}
EOF_MONITOR_SERVICE

    cat > /etc/systemd/system/hy2-relay-monitor.timer <<EOF_MONITOR_TIMER
[Unit]
Description=Run Hysteria SOCKS5 failover check every ${CHECK_INTERVAL} seconds

[Timer]
OnBootSec=10s
OnUnitActiveSec=${CHECK_INTERVAL}s
AccuracySec=1s
Persistent=true
Unit=hy2-relay-monitor.service

[Install]
WantedBy=timers.target
EOF_MONITOR_TIMER

    cat > /etc/systemd/system/hy2-custom-sub.service <<EOF_SUB_SERVICE
[Unit]
Description=Hysteria 2 Custom Local Subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WWW_DIR}
ExecStart=/usr/bin/python3 -m http.server ${SUB_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_SUB_SERVICE

    systemctl daemon-reload
    systemctl enable hy2-custom.service >/dev/null 2>&1
    systemctl enable hy2-custom-sub.service >/dev/null 2>&1
    systemctl enable hy2-relay-monitor.timer >/dev/null 2>&1

    # 先执行一次检查，立刻选择正确出口，不等待首个一分钟周期。
    "$CHECK_SCRIPT" || true
    systemctl restart hy2-custom-sub.service
    systemctl restart hy2-relay-monitor.timer
}

write_openrc_services() {
    cat > /etc/init.d/hy2-custom <<EOF_HY2_OPENRC
#!/sbin/openrc-run
name="hy2-custom"
command="${BIN_PATH}"
command_args="server -c ${CONFIG_FILE}"
command_background=true
pidfile="/run/hy2-custom.pid"
directory="${BASE_DIR}"
depend() {
    need net
}
EOF_HY2_OPENRC
    chmod 0755 /etc/init.d/hy2-custom

    cat > /etc/init.d/hy2-relay-monitor <<EOF_MONITOR_OPENRC
#!/sbin/openrc-run
name="hy2-relay-monitor"
command="${LOOP_SCRIPT}"
command_background=true
pidfile="/run/hy2-relay-monitor.pid"
depend() {
    need net
    after hy2-custom
}
EOF_MONITOR_OPENRC
    chmod 0755 /etc/init.d/hy2-relay-monitor

    cat > /etc/init.d/hy2-custom-sub <<EOF_SUB_OPENRC
#!/sbin/openrc-run
name="hy2-custom-sub"
command="/usr/bin/python3"
command_args="-m http.server ${SUB_PORT}"
command_background=true
pidfile="/run/hy2-custom-sub.pid"
directory="${WWW_DIR}"
depend() {
    need net
}
EOF_SUB_OPENRC
    chmod 0755 /etc/init.d/hy2-custom-sub

    rc-update add hy2-custom default >/dev/null 2>&1 || true
    rc-update add hy2-relay-monitor default >/dev/null 2>&1 || true
    rc-update add hy2-custom-sub default >/dev/null 2>&1 || true

    "$CHECK_SCRIPT" || true
    rc-service hy2-custom-sub restart
    rc-service hy2-relay-monitor restart
}

write_subscription() {
    local server_ip country region remark share_link

    server_ip="$(curl -4fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
    if [ -z "$server_ip" ]; then
        server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi

    country=""
    region=""
    if [ -n "$server_ip" ]; then
        country="$(curl -fsS --max-time 5 "http://ip-api.com/line/${server_ip}?lang=zh-CN&fields=country" 2>/dev/null | head -n1 || true)"
        region="$(curl -fsS --max-time 5 "http://ip-api.com/line/${server_ip}?lang=zh-CN&fields=regionName" 2>/dev/null | head -n1 || true)"
    fi

    if [ -n "$country" ] || [ -n "$region" ]; then
        remark="${country:-本地}：${region:-出口} 自动切换"
    else
        remark="HY2-Relay-Auto-Failover"
    fi

    cat > "${WWW_DIR}/clash.yaml" <<EOF_CLASH
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "${remark}"
    type: hysteria2
    server: ${server_ip}
    port: ${TARGET_PORT}
    password: "${PASSWORD}"
    sni: apps.apple.com
    skip-cert-verify: true
    alpn:
      - h3

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "${remark}"

rules:
  - MATCH,PROXY
EOF_CLASH

    share_link="hysteria2://${PASSWORD}@${server_ip}:${TARGET_PORT}/?sni=apps.apple.com&insecure=1#${remark}"

    printf '%s\n' "$server_ip" > "${BASE_DIR}/server-ip.txt"
    printf '%s\n' "$remark" > "${BASE_DIR}/remark.txt"
    printf '%s\n' "$share_link" > "${BASE_DIR}/share-link.txt"
}

open_firewall() {
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p udp --dport "$TARGET_PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "$TARGET_PORT" -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null || true
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${TARGET_PORT}/udp" >/dev/null 2>&1 || true
        ufw allow "${SUB_PORT}/tcp" >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${TARGET_PORT}/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${SUB_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

show_result() {
    local server_ip remark share_link mode
    server_ip="$(cat "${BASE_DIR}/server-ip.txt" 2>/dev/null || true)"
    remark="$(cat "${BASE_DIR}/remark.txt" 2>/dev/null || true)"
    share_link="$(cat "${BASE_DIR}/share-link.txt" 2>/dev/null || true)"
    mode="$(cat "$STATE_FILE" 2>/dev/null || echo unknown)"

    echo
    echo "========================================================"
    echo "Hysteria 2 自动故障切换安装完成"
    echo "========================================================"
    echo "入口 IP       : ${server_ip:-未知}"
    echo "HY2 UDP 端口  : ${TARGET_PORT}"
    echo "订阅 TCP 端口 : ${SUB_PORT}"
    echo "2号 SOCKS5    : ${RELAY_HOST}:${RELAY_PORT}"
    echo "检测周期       : ${CHECK_INTERVAL} 秒"
    echo "当前出口模式   : ${mode}"
    echo "--------------------------------------------------------"
    echo "relay  = 2号 SOCKS5 台湾家宽"
    echo "direct = 1号服务器本地 IPv4"
    echo "--------------------------------------------------------"
    echo "Clash 订阅："
    echo "http://${server_ip}:${SUB_PORT}/clash.yaml"
    echo "--------------------------------------------------------"
    echo "分享链接："
    echo "$share_link"
    echo "--------------------------------------------------------"
    if command -v systemctl >/dev/null 2>&1; then
        echo "查看切换日志：journalctl -u hy2-relay-monitor.service -f"
        echo "手动立即检测：systemctl start hy2-relay-monitor.service"
    else
        echo "查看当前模式：cat ${STATE_FILE}"
        echo "手动立即检测：${CHECK_SCRIPT}"
    fi
    echo "========================================================"
}

main() {
    install_dependencies

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop hy2-relay-monitor.timer hy2-custom.service hy2-custom-sub.service 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service hy2-relay-monitor stop 2>/dev/null || true
        rc-service hy2-custom stop 2>/dev/null || true
        rc-service hy2-custom-sub stop 2>/dev/null || true
    fi

    download_hysteria
    prepare_files
    write_check_script
    write_subscription
    open_firewall

    if command -v systemctl >/dev/null 2>&1; then
        write_systemd_services
    elif command -v rc-update >/dev/null 2>&1; then
        write_openrc_services
    else
        fatal "系统既没有 systemd，也没有 OpenRC"
    fi

    show_result
}

main "$@"
