#!/bin/bash

# ====================================================
# Hysteria 2 智能极速版
# 特性：
# 1. 自动检测 IPv4/IPv6
# 2. 双栈环境下强制优先 IPv4 出口 (速度更快)
# 3. 彻底解除限速 (无视客户端限制)
# ====================================================

# 0. 检查 Root
if [[ $EUID -ne 0 ]]; then echo "必须 root 运行"; exit 1; fi

echo "========================================================"
echo "    正在运行网络环境智能检测..."
echo "========================================================"

# 1. 网络环境检测与 DNS 修复
chattr -i /etc/resolv.conf >/dev/null 2>&1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 检测 IP 连通性
HAVE_V4=$(curl -s4m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)
HAVE_V6=$(curl -s6m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)

if [[ "$HAVE_V4" == "1" && "$HAVE_V6" == "1" ]]; then
    echo "[*] 检测到双栈网络 (IPv4 + IPv6)"
    echo "[*] 正在配置系统优先使用 IPv4 出口 (提升速度)..."
    
    # 修改 gai.conf 优先级，让系统偏向 IPv4
    if grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "    - 优先级配置已存在"
    else
        # 如果文件不存在或被注释，则追加配置
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        echo "    - 已设置 IPv4 优先"
    fi
elif [[ "$HAVE_V4" == "1" ]]; then
    echo "[*] 检测到纯 IPv4 网络，无需调整。"
else
    echo "[*] 检测到纯 IPv6 网络，保持默认。"
fi

echo "========================================================"
echo "    正在部署 Hysteria 2..."
echo "========================================================"

# 2. 准备目录
mkdir -p /etc/hysteria
cd /etc/hysteria
rm -f server.crt server.key config.yaml

# 3. 生成自签名证书 (apps.apple.com)
openssl req -x509 -nodes -newkey rsa:2048 -keyout server.key -out server.crt -days 3650 -subj "/CN=apps.apple.com" 2>/dev/null

# 4. 下载核心
ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64" ;;
    aarch64) URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-arm64" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

wget -qO /usr/local/bin/hysteria "$URL"
chmod +x /usr/local/bin/hysteria

# 5. 生成配置文件
PASSWORD=$(date +%s%N | md5sum | head -c 16)
REAL_PORT=8899

cat > config.yaml <<EOF
listen: :$REAL_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$PASSWORD"

# 服务器端强制不限速
bandwidth:
  up: 10 gbps
  down: 10 gbps

# 无视客户端限速建议
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

# 6. iptables 端口转发
iptables -t nat -D PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT 2>/dev/null || true
iptables -t nat -A PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
elif command -v service >/dev/null 2>&1; then
    service iptables save 2>/dev/null || true
fi

# 7. 系统服务
cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStart=/usr/local/bin/hysteria server -c config.yaml
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 8. 启动
systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server

# 9. 防火墙
if command -v ufw >/dev/null 2>&1; then
    ufw allow $REAL_PORT/udp >/dev/null 2>&1
    ufw allow 50000:65535/udp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
else
    iptables -I INPUT -p udp --dport $REAL_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport 50000:65535 -j ACCEPT
fi

# 10. 智能获取 IP 和地区
echo "[*] 正在识别服务器信息..."
# 优先获取 IPv4 地址
IP=$(curl -s4m3 ifconfig.me || curl -s6m3 ifconfig.me)

# 使用 regionName 获取 "州/省"
LOC_INFO=$(curl -s --max-time 5 "http://ip-api.com/line/$IP?lang=zh-CN&fields=country,regionName")

if [[ -n "$LOC_INFO" ]]; then
    COUNTRY=$(echo "$LOC_INFO" | sed -n '1p')
    REGION=$(echo "$LOC_INFO" | sed -n '2p')
    REMARK="${COUNTRY}：${REGION} HY2"
else
    REMARK="Hysteria2-Auto"
fi

HOP_PORT=55555
SHARE_LINK="hysteria2://$PASSWORD@$IP:$HOP_PORT/?sni=apps.apple.com&insecure=1#$REMARK"

echo ""
echo "========================================================"
echo "    安装完成！智能优先 IPv4 版"
echo "========================================================"
echo "IP 地址: $IP"
echo "地区备注: $REMARK"
echo "--------------------------------------------------------"
echo "小火箭专用链接："
echo ""
echo "$SHARE_LINK"
echo ""
echo "--------------------------------------------------------"
echo "【已执行优化】"
echo "1. 自动检测到 IPv4/IPv6 环境"
if [[ "$HAVE_V4" == "1" && "$HAVE_V6" == "1" ]]; then
    echo "2. 已设置系统级 IPv4 优先 (解决 GCP 双栈路由差的问题)"
fi
echo "3. 已解除带宽限制，忽略客户端限速请求"
echo "========================================================"
