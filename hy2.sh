#!/bin/bash

# ====================================================
# Hysteria 2 端口跳跃版 (Apple伪装 + 州级定位 + HY2后缀)
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
echo "    正在部署 Hysteria 2 (Apple伪装 + 地区HY2)..."
echo "========================================================"

# 2. 准备目录
mkdir -p /etc/hysteria
cd /etc/hysteria
rm -f server.crt server.key config.yaml

# 3. 生成自签名证书 (apps.apple.com)
echo "[*] 生成伪装证书..."
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

# 5. 生成配置文件 (监听 8899)
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

masquerade:
  type: proxy
  proxy:
    url: https://apps.apple.com/
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
EOF

# 6. 配置 iptables 端口转发
echo "[*] 配置端口跳跃 (50000:65535 -> $REAL_PORT)..."
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

# 9. 配置防火墙
if command -v ufw >/dev/null 2>&1; then
    ufw allow $REAL_PORT/udp
    ufw allow 50000:65535/udp
    ufw reload
else
    iptables -I INPUT -p udp --dport $REAL_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport 50000:65535 -j ACCEPT
fi

# 10. 获取 IP 和 地区信息 (加后缀版)
echo "[*] 正在识别服务器地区..."
IP=$(curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}')

# 使用 regionName 获取 "州/省" 级别
LOC_INFO=$(curl -s --max-time 5 "http://ip-api.com/line?lang=zh-CN&fields=country,regionName")

if [[ -n "$LOC_INFO" ]]; then
    COUNTRY=$(echo "$LOC_INFO" | sed -n '1p')
    REGION=$(echo "$LOC_INFO" | sed -n '2p')
    
    # 【这里修改了】在最后加上 HY2
    REMARK="${COUNTRY}：${REGION} HY2"
else
    REMARK="Hysteria2-Hopping"
fi

HOP_PORT=55555
SHARE_LINK="hysteria2://$PASSWORD@$IP:$HOP_PORT/?sni=apps.apple.com&insecure=1#$REMARK"

echo ""
echo "========================================================"
echo "    安装完成！端口跳跃版 (Apple 伪装)"
echo "========================================================"
echo "IP 地址: $IP"
echo "地区备注: $REMARK"
echo "端口范围: 50000 - 65535"
echo "--------------------------------------------------------"
echo "小火箭专用链接："
echo ""
echo "$SHARE_LINK"
echo ""
echo "--------------------------------------------------------"
echo "【GCP 设置提醒】"
echo "请务必去 GCP 防火墙放行 UDP 协议，端口 50000-65535"
echo "========================================================"
