#!/bin/bash

# ====================================================
# Hysteria 2 完美持久化版
# 特性：
# 1. 重启后自动恢复 (修复重启无法连接问题)
# 2. 再次运行脚本时，自动保留旧密码 (不再变动)
# 3. 包含之前的“智能IPv4”和“无限速”优化
# ====================================================

# 0. 检查 Root
if [[ $EUID -ne 0 ]]; then echo "必须 root 运行"; exit 1; fi

# 1. 安装持久化工具 (解决重启失效的关键)
# 针对 Debian/Ubuntu 系统，防止 iptables 规则重启丢失
if [ -f /etc/debian_version ]; then
    echo "[*] 安装系统防火墙持久化工具..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    # 自动安装 iptables-persistent 并不弹出配置框
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
    apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1
fi

echo "========================================================"
echo "    正在运行 Hysteria 2 部署 (持久化版)..."
echo "========================================================"

# 2. 智能网络检测 (IPv4 优先)
chattr -i /etc/resolv.conf >/dev/null 2>&1
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

HAVE_V4=$(curl -s4m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)
HAVE_V6=$(curl -s6m3 https://ip.sb -k | grep -q . && echo 1 || echo 0)

if [[ "$HAVE_V4" == "1" && "$HAVE_V6" == "1" ]]; then
    if grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        : # 配置已存在
    else
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        echo "[*] 已设置系统优先使用 IPv4 出口"
    fi
fi

# 3. 准备目录
mkdir -p /etc/hysteria

# 4. 核心逻辑：密码保留机制
CONFIG_FILE="/etc/hysteria/config.yaml"
OLD_PASSWORD=""

if [[ -f "$CONFIG_FILE" ]]; then
    # 尝试从旧配置中提取密码
    OLD_PASSWORD=$(grep 'password:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"')
fi

if [[ -n "$OLD_PASSWORD" ]]; then
    echo "[*] 检测到已安装，保留当前密码: $OLD_PASSWORD"
    PASSWORD="$OLD_PASSWORD"
else
    echo "[*] 首次安装 (或无法读取旧配置)，生成新密码..."
    PASSWORD=$(date +%s%N | md5sum | head -c 16)
fi

# 5. 生成/保留证书
if [[ ! -f "/etc/hysteria/server.key" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=apps.apple.com" 2>/dev/null
fi

# 6. 下载/更新核心
ARCH=$(uname -m)
case $ARCH in
    x86_64)  URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-amd64" ;;
    aarch64) URL="https://ghfast.top/https://github.com/apernet/hysteria/releases/download/app%2Fv2.2.4/hysteria-linux-arm64" ;;
    *)       echo "不支持的架构: $ARCH"; exit 1 ;;
esac
wget -qO /usr/local/bin/hysteria "$URL" && chmod +x /usr/local/bin/hysteria

# 7. 写入配置 (使用确定的 PASSWORD)
REAL_PORT=8899
cat > config.yaml <<EOF
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

# 8. 配置 iptables 并持久化保存
# 清理旧规则
iptables -t nat -D PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT 2>/dev/null || true
# 添加规则
iptables -t nat -A PREROUTING -p udp --dport 50000:65535 -j DNAT --to-destination :$REAL_PORT

# 【关键】保存规则到系统启动项
echo "[*] 保存防火墙规则 (确保重启有效)..."
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1
    netfilter-persistent reload >/dev/null 2>&1
elif command -v service >/dev/null 2>&1; then
    service iptables save >/dev/null 2>&1
fi

# 9. 系统服务
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

systemctl daemon-reload
systemctl enable hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server

# 10. 防火墙放行
if command -v ufw >/dev/null 2>&1; then
    ufw allow $REAL_PORT/udp >/dev/null 2>&1
    ufw allow 50000:65535/udp >/dev/null 2>&1
    ufw reload >/dev/null 2>&1
else
    iptables -I INPUT -p udp --dport $REAL_PORT -j ACCEPT
    iptables -I INPUT -p udp --dport 50000:65535 -j ACCEPT
fi

# 11. 信息输出
echo "[*] 正在识别服务器信息..."
IP=$(curl -s4m3 ifconfig.me || curl -s6m3 ifconfig.me)
LOC_INFO=$(curl -s --max-time 5 "http://ip-api.com/line/$IP?lang=zh-CN&fields=country,regionName")
if [[ -n "$LOC_INFO" ]]; then
    COUNTRY=$(echo "$LOC_INFO" | sed -n '1p')
    REGION=$(echo "$LOC_INFO" | sed -n '2p')
    REMARK="${COUNTRY}：${REGION} HY2"
else
    REMARK="Hysteria2-Persistent"
fi

HOP_PORT=55555
SHARE_LINK="hysteria2://$PASSWORD@$IP:$HOP_PORT/?sni=apps.apple.com&insecure=1#$REMARK"

echo ""
echo "========================================================"
echo "    安装完成！永久持久化版"
echo "========================================================"
echo "IP 地址: $IP"
echo "地区备注: $REMARK"
echo "当前密码: $PASSWORD"
echo "--------------------------------------------------------"
echo "1. 此脚本已开启【重启保护】，重启服务器后无需再次运行。"
echo "2. 再次运行此脚本时，【密码不会改变】，方便维护。"
echo "--------------------------------------------------------"
echo "小火箭专用链接："
echo ""
echo "$SHARE_LINK"
echo ""
echo "========================================================"
