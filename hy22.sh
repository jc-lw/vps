#!/bin/sh

# ====================================================
# Hysteria 2 极简共存版 (固定密码 + 单端口 2328)
# 特性：
# 1. 绝对隔离：独立二进制文件、独立配置夹、独立进程名
# 2. 与 v2bx / 面板环境完美共存，互不干扰
# 3. 彻底移除端口跳跃，仅使用纯净 UDP 2328 端口
# 4. 本地订阅服务运行在 8180 端口 (防 8080 冲突)
# ====================================================

# 0. 检查 Root
if [ "$(id -u)" != "0" ]; then echo "必须 root 运行"; exit 1; fi

echo "========================================================"
echo "    正在部署 Hysteria 2 (v2bx 完美共存独立版)..."
echo "========================================================"

# 0.5 检查并安装依赖
echo "[*] 检查系统环境 (python3, curl, openssl, wget)..."
if command -v apk >/dev/null 2>&1; then
    apk update -q
    apk add python3 curl openssl wget -q
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -y -qq
    apt-get install -y python3 curl openssl wget -qq
elif command -v yum >/dev/null 2>&1; then
    yum install -y python3 curl openssl wget -q
fi

# 1. 智能网络检测 (IPv4 优先)
chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

HAVE_V4=$(curl -s4m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)
HAVE_V6=$(curl -s6m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)

if [ "$HAVE_V4" = "1" ] && [ "$HAVE_V6" = "1" ]; then
    if grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        : 
    else
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf 2>/dev/null || true
    fi
fi

# 2. 准备沙盒目录 (全面改名为 hy2-custom)
mkdir -p /etc/hy2-custom
mkdir -p /etc/hy2-custom/www

# 3. 密码与端口设定
PASSWORD="e3a5bb40be52de65"
TARGET_PORT=2328

# 4. 证书处理 (隔离目录)
if [ ! -f "/etc/hy2-custom/server.key" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hy2-custom/server.key -out /etc/hy2-custom/server.crt -days 3650 -subj "/CN=apps.apple.com" 2>/dev/null
fi

# 5. 下载核心并重命名为 hy2-custom (防止覆盖 v2bx 的文件)
echo "[*] 正在准备独立运行核心..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop hy2-custom 2>/dev/null || true
elif command -v rc-service >/dev/null 2>&1; then
    rc-service hy2-custom stop 2>/dev/null || true
fi
rm -f /usr/local/bin/hy2-custom

ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64" ;;
    aarch64) URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-arm64" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

wget -qO /usr/local/bin/hy2-custom "$URL" && chmod +x /usr/local/bin/hy2-custom

# 6. 写入独立配置
cat > /etc/hy2-custom/config.yaml <<EOF
listen: :$TARGET_PORT

tls:
  cert: /etc/hy2-custom/server.crt
  key: /etc/hy2-custom/server.key

auth:
  type: password
  password: "$PASSWORD"

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
EOF

# 7. 注册独立系统服务 (Systemd / OpenRC 兼容)
if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/hy2-custom.service <<EOF
[Unit]
Description=Hysteria 2 Custom Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hy2-custom
ExecStart=/usr/local/bin/hy2-custom server -c /etc/hy2-custom/config.yaml
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hy2-custom >/dev/null 2>&1
    systemctl restart hy2-custom
elif command -v rc-update >/dev/null 2>&1; then
    cat > /etc/init.d/hy2-custom <<EOF
#!/sbin/openrc-run
name="hy2-custom"
command="/usr/local/bin/hy2-custom"
command_args="server -c /etc/hy2-custom/config.yaml"
command_background=true
pidfile="/var/run/hy2-custom.pid"
depend() {
    need net
}
EOF
    chmod +x /etc/init.d/hy2-custom
    rc-update add hy2-custom default >/dev/null 2>&1
    rc-service hy2-custom restart >/dev/null 2>&1
fi

# 8. 识别服务器信息并准备变量
IP=$(curl -s4m3 ifconfig.me || curl -s6m3 ifconfig.me)
LOC_INFO=$(curl -s --max-time 5 "http://ip-api.com/line/$IP?lang=zh-CN&fields=country,regionName")
if [ -n "$LOC_INFO" ]; then
    COUNTRY=$(echo "$LOC_INFO" | sed -n '1p')
    REGION=$(echo "$LOC_INFO" | sed -n '2p')
    REMARK="${COUNTRY}：${REGION} HY2独立版"
else
    REMARK="Hysteria2-Custom"
fi

# ==========================================
# 9. 搭建本地订阅服务 (Clash YAML 生成)
# ==========================================
SUB_PORT=8180
SUB_DIR="/etc/hy2-custom/www"

if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport $SUB_PORT -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport $TARGET_PORT -j ACCEPT 2>/dev/null || true
fi

cat > $SUB_DIR/clash.yaml <<EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "${REMARK}"
    type: hysteria2
    server: ${IP}
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
      - "${REMARK}"

rules:
  - MATCH,PROXY
EOF

if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/hy2-custom-sub.service <<EOF
[Unit]
Description=Hysteria 2 Custom Local Sub
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$SUB_DIR
ExecStart=/usr/bin/python3 -m http.server $SUB_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hy2-custom-sub >/dev/null 2>&1
    systemctl restart hy2-custom-sub
    
    HY2_STATUS=$(systemctl is-active hy2-custom)
    SUB_STATUS=$(systemctl is-active hy2-custom-sub)
elif command -v rc-update >/dev/null 2>&1; then
    cat > /etc/init.d/hy2-custom-sub <<EOF
#!/sbin/openrc-run
name="hy2-custom-sub"
command="/usr/bin/python3"
command_args="-m http.server $SUB_PORT"
command_background=true
pidfile="/var/run/hy2-custom-sub.pid"
directory="$SUB_DIR"
depend() {
    need net
}
EOF
    chmod +x /etc/init.d/hy2-custom-sub
    rc-update add hy2-custom-sub default >/dev/null 2>&1
    rc-service hy2-custom-sub restart >/dev/null 2>&1

    rc-service hy2-custom status 2>/dev/null | grep -q "started" && HY2_STATUS="active" || HY2_STATUS="inactive"
    rc-service hy2-custom-sub status 2>/dev/null | grep -q "started" && SUB_STATUS="active" || SUB_STATUS="inactive"
fi

# 10. 最终输出
SHARE_LINK="hysteria2://$PASSWORD@$IP:$TARGET_PORT/?sni=apps.apple.com&insecure=1#$REMARK"

echo ""
echo "========================================================"
echo "    共存版安装完成！(独立进程 + 纯净端口 2328)"
echo "========================================================"
echo "IP 地址: $IP"
echo "地区备注: $REMARK"
echo "节点端口: $TARGET_PORT (独立直连 UDP)"
echo "固定密码: $PASSWORD"
echo "--------------------------------------------------------"
echo "HY2 独立进程状态       : $HY2_STATUS"
echo "本地订阅服务状态       : $SUB_STATUS"
echo "========================================================"
echo -e "👉 \033[33mClash 本地订阅链接 (适用于 Clash Meta):\033[0m"
echo -e "\033[36mhttp://$IP:$SUB_PORT/clash.yaml\033[0m"
echo "--------------------------------------------------------"
echo -e "👉 \033[33m通用分享链接 (用于小火箭/v2rayN/聚合机器人):\033[0m"
echo -e "\033[32m$SHARE_LINK\033[0m"
echo "========================================================"
