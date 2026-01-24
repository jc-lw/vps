#!/bin/bash

# ====================================================
# Hysteria 2 极速版 (无视客户端限速 + 暴力拥塞控制)
# 监听端口: 8899 (内部)
# 公网端口: 50000-65535 (外部任选)
# ====================================================

# 0. 检查 Root
if [[ $EUID -ne 0 ]]; then echo "必须 root 运行"; exit 1; fi

# 1. 修复 DNS
chattr -i /etc/resolv.conf >/dev/null 2>&1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

echo "========================================================"
echo "    正在部署 Hysteria 2 (无限制极速版)..."
echo "========================================================"

# 2. 准备目录
mkdir -p /etc/hysteria
cd /etc/hysteria
rm -f server.crt server.key config.yaml

# 3. 生成自签名证书 (apps.apple.com)
openssl req -x509 -nodes -newkey rsa:2048 -keyout server.key -out server.crt -days 3650 -subj "/CN=apps.apple.com"

# 4. 下载核心
ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64" ;;
    aarch64) URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-arm64" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

wget -O /usr/local/bin/hysteria "$URL"
chmod +x /usr/local/bin/hysteria

# 5. 生成配置文件 (关键修改点)
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

# 【关键修改】服务器端强制不限速
bandwidth:
  up: 10 gbps
  down: 10 gbps

# 忽略客户端的带宽建议 (强制全速)
ignoreClientBandwidth: true

masquerade:
  type: proxy
  proxy:
    url: https://apps.apple.com/
    rewriteHost: true

# 调大 UDP 缓冲区，防止断流
quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

# 6. 配置 iptables 端口转发
iptables -t nat -D PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT 2>/dev/null || true
iptables -t nat -A PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT

if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
elif command -v service >/dev/null 2>&1; then
    service iptables save 2>/dev/null || true
fi

# 7. 创建服务
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
systemctl enable hysteria-server
systemctl restart hysteria-server

# 9. 防火墙
if command -v ufw >/dev/null 2>&1; then
    ufw allow $REAL_PORT/udp
    ufw allow 50000:65535/udp
    ufw reload
else
    iptables -I INPUT -p udp --dport $REAL_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport 50000:65535 -j ACCEPT
fi

# 10. 获取 IP 和 地区信息
IP=$(curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}')
LOC_INFO=$(curl -s --max-time 5 "http://ip-api.com/line?lang=zh-CN&fields=country,regionName")

if [[ -n "$LOC_INFO" ]]; then
    COUNTRY=$(echo "$LOC_INFO" | sed -n '1p')
    REGION=$(echo "$LOC_INFO" | sed -n '2p')
    REMARK="${COUNTRY}：${REGION} HY2"
else
    REMARK="Hysteria2-Unlimited"
fi

HOP_PORT=55555
SHARE_LINK="hysteria2://$PASSWORD@$IP:$HOP_PORT/?sni=apps.apple.com&insecure=1#$REMARK"

echo ""
echo "========================================================"
echo "    安装完成！无限制极速版"
echo "========================================================"
echo "IP 地址: $IP"
echo "地区备注: $REMARK"
echo "--------------------------------------------------------"
echo "小火箭专用链接："
echo ""
echo "$SHARE_LINK"
echo ""
echo "--------------------------------------------------------"
echo "【优化说明】"
echo "已配置 ignoreClientBandwidth: true"
echo "服务器将忽略客户端的限速请求，强制全速发送。"
echo "========================================================"
