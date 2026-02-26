#!/bin/bash

# ====================================================
# Hysteria 2 终极版 (固定密码 + Clash 本地订阅服务)
# 特性：
# 1. 强制使用固定密码: e3a5bb40be52de65
# 2. 修复端口跳跃 (50000:65535) 和依赖
# 3. 自动生成 Clash Meta (mihomo) 兼容的完整 YAML
# 4. 在 8081 端口运行本地 HTTP 订阅服务
# ====================================================

# 0. 检查 Root
if [[ $EUID -ne 0 ]]; then echo "必须 root 运行"; exit 1; fi

echo "========================================================"
echo "    正在部署 Hysteria 2 (含 Clash 本地订阅服务)..."
echo "========================================================"

# 0.5 检查并安装依赖
echo "[*] 检查系统环境 (iptables & python3)..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y -qq
    apt-get install -y iptables python3 curl -qq
elif command -v yum >/dev/null 2>&1; then
    yum install -y iptables python3 curl -q
fi

# 1. 智能网络检测 (IPv4 优先)
chattr -i /etc/resolv.conf >/dev/null 2>&1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

HAVE_V4=$(curl -s4m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)
HAVE_V6=$(curl -s6m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)

if [[ "$HAVE_V4" == "1" && "$HAVE_V6" == "1" ]]; then
    if grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        : 
    else
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        echo "[*] 已设置系统优先使用 IPv4 出口"
    fi
fi

# 2. 准备目录
mkdir -p /etc/hysteria
mkdir -p /etc/hysteria/www

# 3. 密码设定 (固定密码)
PASSWORD="e3a5bb40be52de65"

# 4. 证书处理
if [[ ! -f "/etc/hysteria/server.key" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=apps.apple.com" 2>/dev/null
fi

# 5. 下载核心 (防止 Text file busy)
echo "[*] 正在停止旧服务释放文件锁定..."
systemctl stop hysteria-server 2>/dev/null || true
rm -f /usr/local/bin/hysteria

ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64" ;;
    aarch64) URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-arm64" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

wget -qO /usr/local/bin/hysteria "$URL" && chmod +x /usr/local/bin/hysteria

# 6. 写入 Hysteria 配置
REAL_PORT=8899
cat > /etc/hysteria/config.yaml <<EOF
listen: :$REAL_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

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

# 7. 配置端口转发 (端口跳跃 50000-65535)
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf
sysctl -p >/dev/null 2>&1

iptables -t nat -D PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT 2>/dev/null || true
iptables -t nat -A PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT

# 8. Hysteria 系统服务
cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server

# 9. 识别服务器信息并准备变量
IP=$(curl -s4m3 ifconfig.me || curl -s6m3 ifconfig.me)
LOC_INFO=$(curl -s --max-time 5 "http://ip-api.com/line/$IP?lang=zh-CN&fields=country,regionName")
if [[ -n "$LOC_INFO" ]]; then
    COUNTRY=$(echo "$LOC_INFO" | sed -n '1p')
    REGION=$(echo "$LOC_INFO" | sed -n '2p')
    REMARK="${COUNTRY}：${REGION} HY2"
else
    REMARK="Hysteria2-Pure"
fi
HOP_PORT=55555

# ==========================================
# 10. 搭建本地订阅服务 (Clash YAML 生成)
# ==========================================
SUB_PORT=8081
SUB_DIR="/etc/hysteria/www"

# 开放订阅端口防火墙
iptables -I INPUT -p tcp --dport $SUB_PORT -j ACCEPT 2>/dev/null || true

# 生成包含完整结构的 Clash YAML 配置文件
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
    port: ${HOP_PORT}
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

# 配置 HTTP 服务的 systemd 守护进程
cat > /etc/systemd/system/hy2-sub.service <<EOF
[Unit]
Description=Hysteria 2 Local Sub Server
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
systemctl enable hy2-sub >/dev/null 2>&1
systemctl restart hy2-sub

# 检查订阅服务状态
SUB_STATUS=$(systemctl is-active hy2-sub)

# 11. 最终输出
SHARE_LINK="hysteria2://$PASSWORD@$IP:$HOP_PORT/?sni=apps.apple.com&insecure=1#$REMARK"

echo ""
echo "========================================================"
echo "    安装完成！(Hysteria 2 + 本地订阅服务)"
echo "========================================================"
echo "IP 地址: $IP"
echo "地区备注: $REMARK"
echo "节点端口: $HOP_PORT (跳跃范围 50000-65535)"
echo "固定密码: $PASSWORD"
echo "--------------------------------------------------------"
echo "Hysteria 2 运行状态    : $(systemctl is-active hysteria-server)"
echo "本地订阅服务状态       : $SUB_STATUS"
echo "========================================================"
echo -e "👉 \033[33mClash 本地订阅链接 (适用于 Clash Meta):\033[0m"
echo -e "\033[36mhttp://$IP:$SUB_PORT/clash.yaml\033[0m"
echo "--------------------------------------------------------"
echo -e "👉 \033[33m通用分享链接 (用于小火箭/v2rayN):\033[0m"
echo -e "\033[32m$SHARE_LINK\033[0m"
echo "========================================================"
