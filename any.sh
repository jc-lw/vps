#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# ============================================================
# AnyTLS + sing-box 一键部署/修复脚本
#
# 固定参数：
#   TCP 端口：4323
#   固定密码：AnyTLS4323Fixed2026
#   TLS SNI ：streaming.hyxyw.com
#
# 说明：
#   1. 可重复执行，会自动覆盖旧的 AnyTLS 配置。
#   2. 不会修改服务器上其他 sing-box 项目。
#   3. 使用自签名证书，客户端必须启用 skip-cert-verify。
#   4. 自动根据公网 IPv4 检测国家并生成节点名称。
#   5. 安装完成会输出 AnyTLS 分享链接和 Clash YAML。
# ============================================================

PORT="4323"
PASSWORD="AnyTLS4323Fixed2026"
SNI="streaming.hyxyw.com"
NODE_NAME=""
SERVER_ADDR="${SERVER_ADDR:-}"
COUNTRY_CODE=""
COUNTRY_NAME=""
COUNTRY_FLAG=""
SINGBOX_VERSION="${SINGBOX_VERSION:-}"

SERVICE_NAME="anytls-singbox"
APP_DIR="/opt/anytls-singbox"
CONFIG_DIR="/etc/anytls-singbox"
BIN_PATH="${APP_DIR}/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_FILE="${CONFIG_DIR}/cert.pem"
KEY_FILE="${CONFIG_DIR}/key.pem"
STATE_FILE="${CONFIG_DIR}/state.env"
SHARE_FILE="${CONFIG_DIR}/share.txt"
CLIENT_FILE="${CONFIG_DIR}/client.json"
CLASH_FILE="${CONFIG_DIR}/clash.yaml"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MANAGER_BIN="/usr/local/bin/anytls"

TMP_DIR=""

red() {
    printf '\033[31m%s\033[0m\n' "$*"
}

green() {
    printf '\033[32m%s\033[0m\n' "$*"
}

yellow() {
    printf '\033[33m%s\033[0m\n' "$*"
}

is_ipv4() {
    local ip="${1:-}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

set_country_name() {
    COUNTRY_CODE="$(printf '%s' "${COUNTRY_CODE:-}" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z')"

    case "$COUNTRY_CODE" in
        HK) COUNTRY_FLAG="🇭🇰"; COUNTRY_NAME="香港" ;;
        US) COUNTRY_FLAG="🇺🇸"; COUNTRY_NAME="美国" ;;
        TW) COUNTRY_FLAG="🇹🇼"; COUNTRY_NAME="台湾" ;;
        SG) COUNTRY_FLAG="🇸🇬"; COUNTRY_NAME="新加坡" ;;
        JP) COUNTRY_FLAG="🇯🇵"; COUNTRY_NAME="日本" ;;
        KR) COUNTRY_FLAG="🇰🇷"; COUNTRY_NAME="韩国" ;;
        GB) COUNTRY_FLAG="🇬🇧"; COUNTRY_NAME="英国" ;;
        FR) COUNTRY_FLAG="🇫🇷"; COUNTRY_NAME="法国" ;;
        DE) COUNTRY_FLAG="🇩🇪"; COUNTRY_NAME="德国" ;;
        CA) COUNTRY_FLAG="🇨🇦"; COUNTRY_NAME="加拿大" ;;
        AU) COUNTRY_FLAG="🇦🇺"; COUNTRY_NAME="澳大利亚" ;;
        NL) COUNTRY_FLAG="🇳🇱"; COUNTRY_NAME="荷兰" ;;
        RU) COUNTRY_FLAG="🇷🇺"; COUNTRY_NAME="俄罗斯" ;;
        IN) COUNTRY_FLAG="🇮🇳"; COUNTRY_NAME="印度" ;;
        BR) COUNTRY_FLAG="🇧🇷"; COUNTRY_NAME="巴西" ;;
        TH) COUNTRY_FLAG="🇹🇭"; COUNTRY_NAME="泰国" ;;
        MY) COUNTRY_FLAG="🇲🇾"; COUNTRY_NAME="马来西亚" ;;
        PH) COUNTRY_FLAG="🇵🇭"; COUNTRY_NAME="菲律宾" ;;
        VN) COUNTRY_FLAG="🇻🇳"; COUNTRY_NAME="越南" ;;
        ID) COUNTRY_FLAG="🇮🇩"; COUNTRY_NAME="印度尼西亚" ;;
        TR) COUNTRY_FLAG="🇹🇷"; COUNTRY_NAME="土耳其" ;;
        AE) COUNTRY_FLAG="🇦🇪"; COUNTRY_NAME="阿联酋" ;;
        CH) COUNTRY_FLAG="🇨🇭"; COUNTRY_NAME="瑞士" ;;
        SE) COUNTRY_FLAG="🇸🇪"; COUNTRY_NAME="瑞典" ;;
        NO) COUNTRY_FLAG="🇳🇴"; COUNTRY_NAME="挪威" ;;
        FI) COUNTRY_FLAG="🇫🇮"; COUNTRY_NAME="芬兰" ;;
        ES) COUNTRY_FLAG="🇪🇸"; COUNTRY_NAME="西班牙" ;;
        IT) COUNTRY_FLAG="🇮🇹"; COUNTRY_NAME="意大利" ;;
        PL) COUNTRY_FLAG="🇵🇱"; COUNTRY_NAME="波兰" ;;
        CZ) COUNTRY_FLAG="🇨🇿"; COUNTRY_NAME="捷克" ;;
        AT) COUNTRY_FLAG="🇦🇹"; COUNTRY_NAME="奥地利" ;;
        BE) COUNTRY_FLAG="🇧🇪"; COUNTRY_NAME="比利时" ;;
        IE) COUNTRY_FLAG="🇮🇪"; COUNTRY_NAME="爱尔兰" ;;
        DK) COUNTRY_FLAG="🇩🇰"; COUNTRY_NAME="丹麦" ;;
        NZ) COUNTRY_FLAG="🇳🇿"; COUNTRY_NAME="新西兰" ;;
        ZA) COUNTRY_FLAG="🇿🇦"; COUNTRY_NAME="南非" ;;
        MX) COUNTRY_FLAG="🇲🇽"; COUNTRY_NAME="墨西哥" ;;
        CL) COUNTRY_FLAG="🇨🇱"; COUNTRY_NAME="智利" ;;
        AR) COUNTRY_FLAG="🇦🇷"; COUNTRY_NAME="阿根廷" ;;
        PE) COUNTRY_FLAG="🇵🇪"; COUNTRY_NAME="秘鲁" ;;
        CO) COUNTRY_FLAG="🇨🇴"; COUNTRY_NAME="哥伦比亚" ;;
        PT) COUNTRY_FLAG="🇵🇹"; COUNTRY_NAME="葡萄牙" ;;
        LU) COUNTRY_FLAG="🇱🇺"; COUNTRY_NAME="卢森堡" ;;
        RO) COUNTRY_FLAG="🇷🇴"; COUNTRY_NAME="罗马尼亚" ;;
        BG) COUNTRY_FLAG="🇧🇬"; COUNTRY_NAME="保加利亚" ;;
        UA) COUNTRY_FLAG="🇺🇦"; COUNTRY_NAME="乌克兰" ;;
        IL) COUNTRY_FLAG="🇮🇱"; COUNTRY_NAME="以色列" ;;
        SA) COUNTRY_FLAG="🇸🇦"; COUNTRY_NAME="沙特阿拉伯" ;;
        QA) COUNTRY_FLAG="🇶🇦"; COUNTRY_NAME="卡塔尔" ;;
        KZ) COUNTRY_FLAG="🇰🇿"; COUNTRY_NAME="哈萨克斯坦" ;;
        *)  COUNTRY_FLAG="🌐"; COUNTRY_NAME="未知地区"; COUNTRY_CODE="${COUNTRY_CODE:-XX}" ;;
    esac

    NODE_NAME="${COUNTRY_FLAG} ${COUNTRY_NAME} 01 | ANYTLS"
}

detect_server_location() {
    local trace=""
    local detected_ip=""
    local detected_code=""
    local country_json=""

    echo "正在检测服务器公网 IP 和国家地区..."

    trace="$(
        curl -4 -fsS             --max-time 10             https://www.cloudflare.com/cdn-cgi/trace             2>/dev/null || true
    )"

    detected_ip="$(
        printf '%s\n' "$trace" |
            awk -F= '$1 == "ip" { print $2; exit }' |
            tr -d '[:space:]'
    )"

    detected_code="$(
        printf '%s\n' "$trace" |
            awk -F= '$1 == "loc" { print $2; exit }' |
            tr -d '[:space:]' |
            tr '[:lower:]' '[:upper:]'
    )"

    if [ -z "$SERVER_ADDR" ] && is_ipv4 "$detected_ip"; then
        SERVER_ADDR="$detected_ip"
    fi

    if [ -z "$SERVER_ADDR" ]; then
        detected_ip="$(
            curl -4 -fsS                 --max-time 10                 https://api.ipify.org                 2>/dev/null || true
        )"
        detected_ip="$(printf '%s' "$detected_ip" | tr -d '[:space:]')"

        if is_ipv4 "$detected_ip"; then
            SERVER_ADDR="$detected_ip"
        fi
    fi

    if ! [[ "$detected_code" =~ ^[A-Z]{2}$ ]] ||
       [ "$detected_code" = "XX" ]; then
        if [ -n "$SERVER_ADDR" ] && [ "$SERVER_ADDR" != "YOUR_SERVER_IP" ]; then
            country_json="$(
                curl -4 -fsS                     --max-time 10                     "https://api.country.is/${SERVER_ADDR}"                     2>/dev/null || true
            )"

            detected_code="$(
                printf '%s' "$country_json" |
                    sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' |
                    head -n 1 |
                    tr '[:lower:]' '[:upper:]'
            )"
        fi
    fi

    if ! [[ "$detected_code" =~ ^[A-Z]{2}$ ]] ||
       [ "$detected_code" = "XX" ]; then
        detected_code="$(
            curl -4 -fsS                 --max-time 10                 https://ipapi.co/country/                 2>/dev/null |
                tr -d '[:space:]' |
                tr '[:lower:]' '[:upper:]' || true
        )"
    fi

    COUNTRY_CODE="$detected_code"
    set_country_name

    if [ -z "$SERVER_ADDR" ]; then
        SERVER_ADDR="YOUR_SERVER_IP"
    fi

    SERVER_ADDR="$(printf '%s' "$SERVER_ADDR" | tr -d '[:space:]')"

    echo "公网 IP    ：${SERVER_ADDR}"
    echo "国家代码   ：${COUNTRY_CODE}"
    echo "国家地区   ：${COUNTRY_FLAG} ${COUNTRY_NAME}"
    echo "节点名称   ：${NODE_NAME}"
}

cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

on_error() {
    local exit_code=$?
    red "执行失败，出错行：${BASH_LINENO[0]}，退出码：${exit_code}"
    exit "$exit_code"
}
trap on_error ERR

if [ "$(id -u)" -ne 0 ]; then
    red "请使用 root 用户执行此脚本。"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    red "当前系统没有 systemd，无法部署服务。"
    exit 1
fi

echo "============================================================"
echo " AnyTLS 一键部署/修复"
echo "============================================================"
echo "端口       : ${PORT}/TCP"
echo "固定密码   : ${PASSWORD}"
echo "TLS SNI    : ${SNI}"
echo "节点名称   : 安装依赖后自动检测国家"
echo "============================================================"
echo

echo "[1/10] 安装依赖..."

if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        curl \
        ca-certificates \
        openssl \
        tar \
        gzip \
        iproute2

    apt-get install -y qrencode >/dev/null 2>&1 || true

elif command -v dnf >/dev/null 2>&1; then
    dnf install -y \
        curl \
        ca-certificates \
        openssl \
        tar \
        gzip \
        iproute

    dnf install -y qrencode >/dev/null 2>&1 || true

elif command -v yum >/dev/null 2>&1; then
    yum install -y \
        curl \
        ca-certificates \
        openssl \
        tar \
        gzip \
        iproute

    yum install -y qrencode >/dev/null 2>&1 || true

else
    red "不支持当前系统的软件包管理器。"
    exit 1
fi

echo
echo "[2/10] 检测服务器国家并生成节点名称..."
detect_server_location

echo
echo "[3/10] 停止旧服务并检查端口..."

systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

sleep 1

if ss -lntH "sport = :${PORT}" 2>/dev/null | grep -q .; then
    red "端口 ${PORT}/TCP 已被其他程序占用："
    ss -lntp "sport = :${PORT}" || true
    exit 1
fi

echo "端口 ${PORT}/TCP 当前可用。"

echo
echo "[4/10] 检测 CPU 架构..."

case "$(uname -m)" in
    x86_64 | amd64)
        ARCH="amd64"
        ;;
    aarch64 | arm64)
        ARCH="arm64"
        ;;
    armv7l | armv7)
        ARCH="armv7"
        ;;
    i386 | i686)
        ARCH="386"
        ;;
    *)
        red "不支持当前 CPU 架构：$(uname -m)"
        exit 1
        ;;
esac

echo "架构：${ARCH}"

echo
echo "[5/10] 下载 sing-box..."

if [ -z "$SINGBOX_VERSION" ]; then
    RELEASE_JSON="$(
        curl -fsSL \
            --retry 3 \
            --connect-timeout 15 \
            https://api.github.com/repos/SagerNet/sing-box/releases/latest \
            2>/dev/null || true
    )"

    SINGBOX_VERSION="$(
        printf '%s' "$RELEASE_JSON" |
            sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' |
            head -n 1
    )"
fi

if [ -z "$SINGBOX_VERSION" ]; then
    LATEST_URL="$(
        curl -fsSLI \
            --retry 3 \
            --connect-timeout 15 \
            -o /dev/null \
            -w '%{url_effective}' \
            https://github.com/SagerNet/sing-box/releases/latest \
            2>/dev/null || true
    )"

    SINGBOX_VERSION="${LATEST_URL##*/}"
    SINGBOX_VERSION="${SINGBOX_VERSION#v}"
fi

if ! [[ "$SINGBOX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    red "无法获取有效 sing-box 版本：${SINGBOX_VERSION}"
    exit 1
fi

echo "sing-box 版本：${SINGBOX_VERSION}"

TMP_DIR="$(mktemp -d)"

PACKAGE_NAME="sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${PACKAGE_NAME}"

curl -fL \
    --retry 5 \
    --retry-delay 3 \
    --connect-timeout 20 \
    -o "${TMP_DIR}/${PACKAGE_NAME}" \
    "$DOWNLOAD_URL"

tar -xzf "${TMP_DIR}/${PACKAGE_NAME}" -C "$TMP_DIR"

EXTRACTED_BIN="$(
    find "$TMP_DIR" \
        -type f \
        -name sing-box \
        2>/dev/null |
        head -n 1
)"

if [ -z "$EXTRACTED_BIN" ]; then
    red "安装包中没有找到 sing-box。"
    exit 1
fi

EXTRACTED_DIR="$(dirname "$EXTRACTED_BIN")"

mkdir -p "$APP_DIR"
rm -rf "${APP_DIR:?}/"*
cp -a "${EXTRACTED_DIR}/." "$APP_DIR/"
chmod 755 "$BIN_PATH"

"$BIN_PATH" version

echo
echo "[6/10] 生成 TLS 自签名证书..."

mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
    cp -a "$CONFIG_FILE" \
        "${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
fi

OPENSSL_CONFIG="${TMP_DIR}/openssl.cnf"

cat >"$OPENSSL_CONFIG" <<EOF_CERT
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = ${SNI}

[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${SNI}
EOF_CERT

openssl req \
    -x509 \
    -nodes \
    -newkey rsa:2048 \
    -sha256 \
    -days 3650 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -config "$OPENSSL_CONFIG" \
    >/dev/null 2>&1

chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

echo "证书 CN/SAN：${SNI}"

echo
echo "[7/10] 写入 AnyTLS 服务端配置..."

cat >"$CONFIG_FILE" <<EOF_CONFIG
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "users": [
        {
          "name": "default",
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "min_version": "1.2",
        "certificate_path": "${CERT_FILE}",
        "key_path": "${KEY_FILE}"
      }
    }
  ]
}
EOF_CONFIG

chmod 600 "$CONFIG_FILE"

"$BIN_PATH" check -c "$CONFIG_FILE"

echo
echo "[8/10] 创建并启动 systemd 服务..."

cat >"$SERVICE_FILE" <<EOF_SERVICE
[Unit]
Description=AnyTLS Server powered by sing-box
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
Environment=LD_LIBRARY_PATH=${APP_DIR}
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
systemctl restart "$SERVICE_NAME"

sleep 2

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    red "AnyTLS 服务启动失败，最近日志："
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
    exit 1
fi

if ! ss -lntH "sport = :${PORT}" 2>/dev/null | grep -q .; then
    red "服务已启动，但 ${PORT}/TCP 没有监听。"
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
    exit 1
fi

echo "服务已正常启动并监听 ${PORT}/TCP。"

echo
echo "[9/10] 放行系统防火墙..."

if command -v ufw >/dev/null 2>&1 &&
   ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null
    echo "已放行 UFW：${PORT}/TCP"
fi

if command -v firewall-cmd >/dev/null 2>&1 &&
   systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent \
        --add-port="${PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    echo "已放行 firewalld：${PORT}/TCP"
fi

if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT \
        -p tcp \
        --dport "$PORT" \
        -j ACCEPT \
        2>/dev/null ||
    iptables -I INPUT 1 \
        -p tcp \
        --dport "$PORT" \
        -j ACCEPT
fi

echo
echo "[10/10] 生成分享链接和 Clash 配置..."

# 公网 IP 和国家名称已在第 2 步检测。
# 若前面的在线接口全部失败，这里再尝试读取系统出口 IPv4。
if [ -z "$SERVER_ADDR" ] || [ "$SERVER_ADDR" = "YOUR_SERVER_IP" ]; then
    FALLBACK_ADDR="$(
        ip -4 route get 1.1.1.1 2>/dev/null |
            awk '{
                for (i = 1; i <= NF; i++) {
                    if ($i == "src") {
                        print $(i + 1)
                        exit
                    }
                }
            }'
    )"

    if is_ipv4 "$FALLBACK_ADDR"; then
        SERVER_ADDR="$FALLBACK_ADDR"
    else
        SERVER_ADDR="YOUR_SERVER_IP"
    fi
fi

SERVER_ADDR="$(printf '%s' "$SERVER_ADDR" | tr -d '[:space:]')"

if [[ "$SERVER_ADDR" == *:* ]]; then
    URI_HOST="[${SERVER_ADDR}]"
else
    URI_HOST="$SERVER_ADDR"
fi

SHARE_LINK="anytls://${PASSWORD}@${URI_HOST}:${PORT}/?sni=${SNI}&insecure=1#${NODE_NAME}"

cat >"$STATE_FILE" <<EOF_STATE
PORT='${PORT}'
PASSWORD='${PASSWORD}'
SNI='${SNI}'
NODE_NAME='${NODE_NAME}'
SERVER_ADDR='${SERVER_ADDR}'
COUNTRY_CODE='${COUNTRY_CODE}'
COUNTRY_NAME='${COUNTRY_NAME}'
COUNTRY_FLAG='${COUNTRY_FLAG}'
EOF_STATE

cat >"$SHARE_FILE" <<EOF_SHARE
${SHARE_LINK}
EOF_SHARE

cat >"$CLIENT_FILE" <<EOF_CLIENT
{
  "type": "anytls",
  "tag": "${NODE_NAME}",
  "server": "${SERVER_ADDR}",
  "server_port": ${PORT},
  "password": "${PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "insecure": true
  }
}
EOF_CLIENT

cat >"$CLASH_FILE" <<EOF_CLASH
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "${NODE_NAME}"
    type: anytls
    server: "${SERVER_ADDR}"
    port: ${PORT}
    password: "${PASSWORD}"
    client-fingerprint: chrome
    udp: true
    sni: "${SNI}"
    skip-cert-verify: true
    idle-session-check-interval: 30
    idle-session-timeout: 30
    min-idle-session: 0

proxy-groups:
  - name: "节点选择"
    type: select
    proxies:
      - "${NODE_NAME}"
      - DIRECT

rules:
  - MATCH,节点选择
EOF_CLASH

chmod 600 \
    "$STATE_FILE" \
    "$SHARE_FILE" \
    "$CLIENT_FILE" \
    "$CLASH_FILE"

cat >"$MANAGER_BIN" <<'EOF_MANAGER'
#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="anytls-singbox"
CONFIG_DIR="/etc/anytls-singbox"
STATE_FILE="${CONFIG_DIR}/state.env"
SHARE_FILE="${CONFIG_DIR}/share.txt"
CLASH_FILE="${CONFIG_DIR}/clash.yaml"

show_info() {
    if [ ! -r "$STATE_FILE" ]; then
        echo "找不到 AnyTLS 状态文件：${STATE_FILE}"
        exit 1
    fi

    # shellcheck disable=SC1090
    . "$STATE_FILE"

    if [[ "$SERVER_ADDR" == *:* ]]; then
        URI_HOST="[${SERVER_ADDR}]"
    else
        URI_HOST="$SERVER_ADDR"
    fi

    LINK="anytls://${PASSWORD}@${URI_HOST}:${PORT}/?sni=${SNI}&insecure=1#${NODE_NAME}"

    echo "============================================================"
    echo "AnyTLS 连接信息"
    echo "============================================================"
    echo "服务器：${SERVER_ADDR}"
    echo "地区  ：${COUNTRY_FLAG:-🌐} ${COUNTRY_NAME:-未知地区}"
    echo "节点名：${NODE_NAME}"
    echo "端口  ：${PORT}/TCP"
    echo "密码  ：${PASSWORD}"
    echo "SNI   ：${SNI}"
    echo "证书验证：跳过"
    echo
    echo "分享链接："
    echo "$LINK"
    echo
    echo "Clash 配置：${CLASH_FILE}"

    if command -v qrencode >/dev/null 2>&1; then
        echo
        qrencode -t ANSIUTF8 "$LINK" || true
    fi
}

case "${1:-info}" in
    info | link)
        show_info
        ;;
    clash)
        cat "$CLASH_FILE"
        ;;
    status)
        systemctl status "$SERVICE_NAME" --no-pager -l
        ;;
    start)
        systemctl start "$SERVICE_NAME"
        ;;
    stop)
        systemctl stop "$SERVICE_NAME"
        ;;
    restart)
        systemctl restart "$SERVICE_NAME"
        ;;
    logs | log)
        journalctl -u "$SERVICE_NAME" -f
        ;;
    check)
        echo "服务状态："
        systemctl is-active "$SERVICE_NAME" || true
        echo
        echo "端口监听："
        ss -lntp | grep ':4323' || true
        echo
        echo "最近日志："
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager
        ;;
    uninstall)
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        rm -rf "/etc/anytls-singbox" "/opt/anytls-singbox"
        rm -f "/usr/local/bin/anytls"
        echo "AnyTLS 已卸载。"
        ;;
    *)
        echo "用法："
        echo "  anytls info       查看连接信息"
        echo "  anytls clash      查看 Clash 配置"
        echo "  anytls status     查看服务状态"
        echo "  anytls start      启动服务"
        echo "  anytls stop       停止服务"
        echo "  anytls restart    重启服务"
        echo "  anytls logs       查看实时日志"
        echo "  anytls check      快速检查"
        echo "  anytls uninstall  卸载服务"
        exit 1
        ;;
esac
EOF_MANAGER

chmod 755 "$MANAGER_BIN"

echo
green "============================================================"
green " AnyTLS 部署/修复成功"
green "============================================================"
echo
echo "服务器地址：${SERVER_ADDR}"
echo "国家地区  ：${COUNTRY_FLAG} ${COUNTRY_NAME} (${COUNTRY_CODE})"
echo "节点名称  ：${NODE_NAME}"
echo "端口      ：${PORT}/TCP"
echo "固定密码  ：${PASSWORD}"
echo "TLS SNI   ：${SNI}"
echo "跳过验证  ：是"
echo
yellow "小猫咪 / NekoBox / sing-box 分享链接："
echo
echo "${SHARE_LINK}"
echo
yellow "Telegram Worker 添加命令："
echo
echo "/add ${SHARE_LINK}"
echo
yellow "Clash Verge 节点内容："
echo
cat "$CLASH_FILE"
echo
echo "配置文件："
echo "  服务端配置：${CONFIG_FILE}"
echo "  分享链接  ：${SHARE_FILE}"
echo "  Clash 配置：${CLASH_FILE}"
echo
echo "管理命令："
echo "  anytls info"
echo "  anytls clash"
echo "  anytls status"
echo "  anytls logs"
echo "  anytls restart"
echo
echo "当前监听："
ss -lntp "sport = :${PORT}" || true
echo
yellow "请确认云平台安全组已放行 TCP ${PORT}。"
yellow "Worker/KV 中旧 AnyTLS 节点必须删除，只保留上面新链接。"
