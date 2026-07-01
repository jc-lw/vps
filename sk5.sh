#!/bin/bash
# 自动化安装并配置 SOCKS5 代理 (Dante Server) + 自动放行防火墙

echo "========================================="
echo "开始安装 Dante Server 与防火墙工具..."
echo "========================================="

# 1. 更新并安装依赖 (加入 iptables-persistent 以便保存规则)
apt-get update
# 设置非交互模式，防止安装 iptables-persistent 时弹出粉红色确认框卡住脚本
DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server iptables-persistent

# 2. 获取服务器的主网卡名称
INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)' | head -n 1)
echo "检测到主网卡为: $INTERFACE"

# 3. 备份并写入新的 SOCKS5 配置
cp /etc/danted.conf /etc/danted.conf.bak
cat <<EOF > /etc/danted.conf
logoutput: syslog
user.privileged: root
user.unprivileged: nobody

# 监听 3333 端口
internal: 0.0.0.0 port = 3333
external: $INTERFACE

# 无密码认证
socksmethod: none
clientmethod: none

# 允许所有出入站数据
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF

# 4. 配置系统防火墙放行 3333 端口
echo "正在配置系统防火墙放行 3333 端口..."

# 使用 iptables 插入规则到最前面
iptables -I INPUT -p tcp --dport 3333 -j ACCEPT

# 如果系统装有 UFW，也同步放行
if command -v ufw > /dev/null 2>&1; then
    ufw allow 3333/tcp > /dev/null 2>&1
fi

# 持久化保存 iptables 规则，确保重启后不失效
netfilter-persistent save || iptables-save > /etc/iptables/rules.v4

# 5. 重启并设置开机自启
systemctl restart danted
systemctl enable danted

echo "========================================="
echo "SOCKS5 代理已成功启动！"
echo "监听端口: 3333"
echo "防火墙状态: 系统层面的 3333 TCP 端口已永久放行"
echo "========================================="
