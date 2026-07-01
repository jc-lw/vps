#!/bin/bash
# 自动化安装并配置 SOCKS5 代理 (Dante Server)

# 1. 更新并安装 dante-server
echo "正在安装 Dante Server..."
apt-get update
apt-get install -y dante-server

# 2. 获取服务器的默认主网卡名称 (例如 eth0, ens3 等)
INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)' | head -n 1)
echo "检测到主网卡为: $INTERFACE"

# 3. 备份默认配置
cp /etc/danted.conf /etc/danted.conf.bak

# 4. 写入新的 SOCKS5 配置 (监听 3333 端口，无密码认证)
cat <<EOF > /etc/danted.conf
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

# 监听端口设置为 3333
internal: 0.0.0.0 port = 3333
external: $INTERFACE

# 认证方式：无认证 (none)
socksmethod: none
clientmethod: none

# 允许所有客户端连接
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

# 允许所有数据转发
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF

# 5. 重启并设置开机自启
systemctl restart danted
systemctl enable danted

echo "========================================="
echo "SOCKS5 代理已成功启动！"
echo "监听端口: 3333"
echo "认证方式: 无认证"
echo "========================================="
