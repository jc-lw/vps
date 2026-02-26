#!/bin/bash

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本"
  exit 1
fi

echo "正在准备环境..."
if command -v apt-get >/dev/null; then
    apt-get update -y && apt-get -y install curl unzip python3
elif command -v yum >/dev/null; then
    yum install -y curl unzip python3
fi

echo "开始调用官方脚本安装/更新 Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

if [ ! -f "/usr/local/bin/xray" ]; then
    echo "错误：Xray 核心文件未找到。"
    exit 1
fi

# 2. 读取或生成核心参数 (持久化逻辑)
VARS_FILE="/usr/local/etc/xray/xray_vars.conf"
mkdir -p /usr/local/etc/xray

if [ -f "$VARS_FILE" ]; then
    echo "✅ 检测到已有的配置记录，直接读取并固定使用..."
    source "$VARS_FILE"
else
    echo "🆕 初次运行或未找到历史记录，正在生成固定的证书和节点参数..."
    
    UUID=$(/usr/local/bin/xray uuid 2>/dev/null)
    if [ -z "$UUID" ]; then
        UUID=$(cat /proc/sys/kernel/random/uuid)
    fi

    KEYS=$(/usr/local/bin/xray x25519 2>&1)
    PRIVATE_KEY=$(echo "$KEYS" | grep -iE "Private" | awk -F ':' '{print $2}' | tr -d ' ' | tr -d '\r')
    PUBLIC_KEY=$(echo "$KEYS" | grep -iE "Public|Password" | awk -F ':' '{print $2}' | tr -d ' ' | tr -d '\r')

    SHORT_ID="16926c59"
    PORT=22233
    DEST_SNI="apps.apple.com"

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        echo "提取密钥失败，请检查脚本兼容性。"
        exit 1
    fi

    # 保存参数供下次复用
    cat <<EOF > "$VARS_FILE"
UUID="$UUID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
PORT="$PORT"
DEST_SNI="$DEST_SNI"
EOF
    echo "✅ 参数已固化保存至 $VARS_FILE"
fi

# 3. 写入 Xray 配置文件
cat <<EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST_SNI:443",
          "xver": 0,
          "serverNames": [
            "$DEST_SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF

# 4. 重启 Xray 服务
echo "正在启动 Xray 服务..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

# 5. 获取当前最新的服务器 IP 与精细地区 (国家+城市)
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ipv4.icanhazip.com)
echo "正在获取服务器所在地区及城市..."

NODE_NAME=$(curl -s http://ip-api.com/json/?lang=zh-CN | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    country = data.get('country', '未知国家')
    city = data.get('city', '未知城市')
    print(f'{country}：{city} VLESS')
except:
    print('未知地区 VLESS')
")

# 6. 生成 VLESS 一键导入链接
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${NODE_NAME}"

# 7. 配置本地 Clash 订阅服务
echo "正在配置本地 Clash 订阅服务..."
SUB_PORT=8081
SUB_DIR="/usr/local/etc/xray/sub"
mkdir -p "$SUB_DIR"

cat <<EOF > "$SUB_DIR/clash.yaml"
proxies:
  - name: "$NODE_NAME"
    type: vless
    server: $SERVER_IP
    port: $PORT
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: $DEST_SNI
    client-fingerprint: chrome
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
EOF

cat <<EOF > /etc/systemd/system/xray-sub.service
[Unit]
Description=Xray Local Clash Subscription Server
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
systemctl enable xray-sub
systemctl restart xray-sub

LOCAL_SUB_URL="http://${SERVER_IP}:${SUB_PORT}/clash.yaml"

# 8. 输出信息
echo ""
echo "=================================================="
echo "          Xray VLESS-Reality 部署完成！"
echo "=================================================="
echo "服务器 IP (Address)    : $SERVER_IP"
echo "连接端口 (Port)        : $PORT"
echo "生成节点名称 (Name)    : $NODE_NAME"
echo "用户 ID (UUID)         : $UUID"
echo "=================================================="
echo "Xray 运行状态          : $(systemctl is-active xray)"
echo "本地订阅服务状态       : $(systemctl is-active xray-sub)"
echo "=================================================="
echo -e "👉 \033[33mClash 本地订阅链接:\033[0m"
echo -e "\033[36m$LOCAL_SUB_URL\033[0m"
echo ""
echo -e "👉 \033[33m通用分享链接 (小火箭 / V2rayN):\033[0m"
echo -e "\033[32m$VLESS_LINK\033[0m"
echo "=================================================="
