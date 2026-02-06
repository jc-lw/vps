#!/bin/bash

# ====================================================
# Hysteria 2 纯净极简版 (路径修复完美版)
# 特性：
# 1. 不安装任何防火墙组件 (如你所愿)
# 2. 保留密码记忆 (升级不换密码)
# 3. 智能 IPv4 优先 + 无限速
# 4. 修复 Systemd 找不到配置文件的致命 Bug
# ====================================================

# 0. 检查 Root
if [[ $EUID -ne 0 ]]; then echo "必须 root 运行"; exit 1; fi

echo "========================================================"
echo "    正在部署 Hysteria 2 (纯净版 - 修复路径问题)..."
echo "========================================================"

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

# 3. 密码记忆逻辑
# 【关键修复】明确指定从 /etc/hysteria 读取旧配置
CONFIG_FILE="/etc/hysteria/config.yaml"
OLD_PASSWORD=""

if [[ -f "$CONFIG_FILE" ]]; then
    # 尝试读取旧密码
    OLD_PASSWORD=$(grep 'password:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
fi

if [[ -n "$OLD_PASSWORD" ]]; then
    echo "[*] 保留当前密码: $OLD_PASSWORD"
    PASSWORD="$OLD_PASSWORD"
else
    echo "[*] 生成新密码..."
    PASSWORD=$(date +%s%N | md5sum | head -c 16)
fi

# 4. 证书处理
if [[ ! -f "/etc/hysteria/server.key" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=apps.apple.com" 2>/dev/null
fi

# 5. 下载核心
ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64" ;;
    aarch64) URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-arm64" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac
# 只有文件不存在时才下载，或者强制覆盖，这里为了稳妥加了 -O
wget -qO /usr/local/bin/hysteria "$URL" && chmod +x /usr/local/bin/hysteria

# 6. 写入配置
REAL_PORT=8899
# 【关键修复】必须写入到 /etc/hysteria/config.yaml，而不是当前目录
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

# 7. 配置端口转发 (这行必须有，否则端口跳跃不生效)
# 这不是防火墙规则，这是路由规则
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-forwarding.conf
sysctl -p >/dev/null 2>&1
iptables -t nat -D PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT 2>/dev/null || true
iptables -t nat -A PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT

# 8. 系统服务
# 【关键修复】ExecStart 使用绝对路径，确保 systemd 肯定能找到配置
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

# 9. 信息输出
echo "[*] 正在识别服务器信息..."
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
SHARE_LINK="hysteria2://$PASSWORD@$IP:$HOP_PORT/?sni=apps.apple.com&insecure=1#$REMARK"

echo ""
echo "========================================================"
echo "    安装完成！(纯净极简版 - 已修复启动路径)"
echo "========================================================"
echo "IP 地址: $IP"
echo "地区备注: $REMARK"
echo "当前密码: $PASSWORD"
echo "--------------------------------------------------------"
echo "此版本已去除防火墙持久化组件。"
echo "注意：如果你重启了服务器，请重新运行此脚本，"
echo "否则端口转发规则(50000-65535)可能会丢失。"
echo "--------------------------------------------------------"
echo "小火箭专用链接："
echo ""
echo "$SHARE_LINK"
echo ""
echo "========================================================"
