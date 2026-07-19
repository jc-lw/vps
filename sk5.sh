cat > /root/install_socks5_3333_noauth.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-3333}"
LISTEN_IP="${LISTEN_IP:-0.0.0.0}"
INSTALL_DIR="/opt/microsocks"
BIN_PATH="/usr/local/bin/microsocks"
SERVICE_FILE="/etc/systemd/system/microsocks.service"

echo "========================================="
echo "MicroSocks SOCKS5 无认证安装脚本"
echo "监听地址: ${LISTEN_IP}"
echo "监听端口: ${PORT}"
echo "认证方式: 无账号密码"
echo "后台运行: systemd"
echo "开机自启: 是"
echo "========================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 用户运行"
  exit 1
fi

echo "[1/6] 安装依赖..."
apt update
apt install -y git build-essential curl ca-certificates iproute2 lsof

echo "[2/6] 下载/更新 MicroSocks..."
if [ -d "${INSTALL_DIR}/.git" ]; then
  git -C "${INSTALL_DIR}" pull --ff-only || true
else
  rm -rf "${INSTALL_DIR}"
  git clone --depth 1 https://github.com/rofl0r/microsocks.git "${INSTALL_DIR}"
fi

echo "[3/6] 编译安装..."
make -C "${INSTALL_DIR}"
install -m 0755 "${INSTALL_DIR}/microsocks" "${BIN_PATH}"

if ! command -v microsocks >/dev/null 2>&1; then
  echo "microsocks 安装失败"
  exit 1
fi

echo "[4/6] 写入 systemd 服务..."
cat > "${SERVICE_FILE}" <<SERVICE
[Unit]
Description=MicroSocks SOCKS5 Proxy No Auth
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=${BIN_PATH} -i ${LISTEN_IP} -p ${PORT}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
SERVICE

echo "[5/6] 配置防火墙放行端口..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" || true
fi

if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" || true
  firewall-cmd --reload || true
fi

echo "[6/6] 启动并设置开机自启..."
systemctl daemon-reload
systemctl enable microsocks
systemctl restart microsocks

sleep 1

echo "========================================="
echo "服务状态："
systemctl status microsocks --no-pager || true
echo "========================================="

if ss -lntp | grep -q ":${PORT} "; then
  echo "✅ SOCKS5 已成功监听 ${LISTEN_IP}:${PORT}"
else
  echo "❌ 端口 ${PORT} 没有监听，查看日志："
  journalctl -u microsocks -n 100 --no-pager
  exit 1
fi

SERVER_IP="$(curl -4 -s --max-time 10 https://ip.sb || true)"

echo "========================================="
echo "安装完成"
echo "服务器 IP: ${SERVER_IP:-你的服务器IP}"
echo "SOCKS5 地址: ${SERVER_IP:-你的服务器IP}:${PORT}"
echo "认证方式: 无认证"
echo
echo "本机测试："
echo "curl -v -x socks5h://127.0.0.1:${PORT} https://ip.sb"
echo
echo "外部测试："
echo "curl -v -x socks5h://${SERVER_IP:-你的服务器IP}:${PORT} https://ip.sb"
echo "========================================="
EOF

chmod +x /root/install_socks5_3333_noauth.sh
bash /root/install_socks5_3333_noauth.sh
