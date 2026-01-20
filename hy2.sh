#!/bin/bash

# ====================================================
# Hysteria 2 端口跳跃版 (Port Hopping)
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
echo "    正在部署 Hysteria 2 (端口跳跃版)..."
echo "========================================================"

# 2. 准备目录
mkdir -p /etc/hysteria
cd /etc/hysteria
rm -f server.crt server.key config.yaml

# 3. 生成自签名证书 (伪装 www.bing.com)
openssl req -x509 -nodes -newkey rsa:2048 -keyout server.key -out server.crt -days 3650 -subj "/CN=www.bing.com"

# 4. 下载核心
ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64" ;;
    aarch64) URL="https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-arm64" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac

wget -O /usr/local/bin/hysteria "$URL"
chmod +x /usr/local/bin/hysteria

# 5. 生成配置文件 (监听 8899)
PASSWORD=$(date +%s%N | md5sum | head -c 16)
REAL_PORT=8899  # 内部实际监听端口

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
    url: https://www.bing.com/
    rewriteHost: true

# 优化 UDP 传输
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
EOF

# 6. 配置 iptables 端口转发 (你的代码)
echo "[*] 配置端口跳跃 (50000:65535 -> $REAL_PORT)..."

# 清理旧规则防止重复
iptables -t nat -D PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT 2>/dev/null || true
# 添加新规则
iptables -t nat -A PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT

# 尝试保存规则 (兼容不同系统)
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
# 注意：DNAT 后，INPUT 链看到的是 8899，所以放行 8899
if command -v ufw >/dev/null 2>&1; then
    ufw allow $REAL_PORT/udp
    ufw allow 50000:65535/udp
    ufw reload
else
    iptables -I INPUT -p udp --dport $REAL_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport 50000:65535 -j ACCEPT
fi

# 10. 输出链接 (随机挑一个端口 55555 生成链接)
IP=$(curl -s --max-time 3 ifconfig.me || hostname -I | awk '{print $1}')
HOP_PORT=55555
SHARE_LINK="hysteria2://$PASSWORD@$IP:$HOP_PORT/?sni=www.bing.com&insecure=1#Aliyun-Hopping"

echo ""
echo "========================================================"
echo "    安装完成！端口跳跃版"
echo "========================================================"
echo "IP: $IP"
echo "密码: $PASSWORD"
echo "协议: Hysteria 2 (UDP)"
echo "端口跳跃范围: 50000 - 65535"
echo "--------------------------------------------------------"
echo "小火箭专用链接 (默认填了 55555 端口)："
echo ""
echo "$SHARE_LINK"
echo ""
echo "--------------------------------------------------------"
echo "【极度重要】阿里云安全组设置"
echo "请去阿里云后台 -> 安全组 -> 添加入方向规则："
echo "协议: UDP"
echo "端口范围: 50000/65535"
echo "源IP: 0.0.0.0/0"
echo "--------------------------------------------------------"
echo "如果 55555 端口不通，你在小火箭里把端口改成 50000-65535"
echo "之间的任意数字都能连！"
echo "========================================================"
