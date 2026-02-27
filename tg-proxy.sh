#!/bin/bash

echo "=================================================="
echo "🚀 开始一键部署 TG Proxy 生产级节点 (Waitress)"
echo "=================================================="

echo -e "\n[1/5] 更新软件源并安装 Python 依赖..."
apt update
apt install python3.13-venv python3-pip -y

echo -e "\n[2/5] 创建项目目录并清理旧环境..."
mkdir -p /root/tg_proxy_node
cd /root/tg_proxy_node
rm -rf venv

echo -e "\n[3/5] 重新创建并激活干净的虚拟环境..."
python3 -m venv venv
source venv/bin/activate

echo -e "\n[4/5] 安装高性能运行模块..."
pip install flask requests waitress

echo -e "\n[5/5] 正在生成核心代理代码 proxy_node.py..."

# 使用 EOF 魔法将 Python 代码直接写入文件
cat << 'EOF' > proxy_node.py
from flask import Flask, Response, request
import requests
import re
from waitress import serve  # 引入工业级服务器

app = Flask(__name__)

# 健康检测接口 (供未来的监控使用)
@app.route('/ping')
def ping():
    return Response("ok", status=200, headers={'Access-Control-Allow-Origin': '*'})

# 核心代理接口
@app.route('/<path:url>', methods=["GET", "OPTIONS"])
def proxy(url):
    # 放行预检请求
    if request.method == "OPTIONS":
        resp = Response()
        resp.headers['Access-Control-Allow-Origin'] = '*'
        resp.headers['Access-Control-Allow-Methods'] = 'GET, OPTIONS'
        resp.headers['Access-Control-Allow-Headers'] = '*'
        return resp

    # 修复双斜杠被 Flask 吞掉的问题
    url = re.sub(r'^(https?:)/+', r'\1//', url)
    if request.query_string:
        url = f"{url}?{request.query_string.decode('utf-8')}"

    if not url.startswith('http'):
        return Response("Invalid URL", status=400, headers={'Access-Control-Allow-Origin': '*'})

    try:
        headers = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"}
        
        # stream=True 极大地优化图片流式传输，防卡死
        res = requests.get(url, headers=headers, stream=True, timeout=15)
        
        # 严格过滤掉会导致浏览器渲染卡顿的 Hop-by-hop HTTP 头
        excluded_headers = ['content-encoding', 'content-length', 'transfer-encoding', 'connection']
        resp_headers = [(name, value) for (name, value) in res.raw.headers.items()
                        if name.lower() not in excluded_headers]
        
        resp_headers.append(('Access-Control-Allow-Origin', '*'))
        
        return Response(res.content, res.status_code, resp_headers)
        
    except Exception as e:
        # 如果网络错误，直接返回 502，Worker 会立刻淘汰这个节点
        return Response(f"Node Proxy Error: {str(e)}", status=502, headers={'Access-Control-Allow-Origin': '*'})

if __name__ == '__main__':
    print("🚀 生产级代理节点已启动 (Waitress Engine) - 监听 5000 端口")
    # 使用 Waitress 代替 app.run()，多线程无阻塞拉取图片
    serve(app, host='0.0.0.0', port=5000, threads=16)
EOF

echo -e "✅ Python 代码写入完成！"

echo -e "\n[6/6] 检查并配置 PM2 后台守护进程..."
# 检查是否安装了 pm2，如果没有则自动安装 nodejs 和 pm2
if ! command -v pm2 &> /dev/null
then
    echo "⚠️ 未检测到 PM2，正在自动安装 Node.js 和 PM2..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt install -y nodejs
    npm install -g pm2
fi

# 清理可能存在的旧进程，防止端口冲突
pm2 delete tg-proxy-node 2>/dev/null || true

# 使用 PM2 挂载全新的代理节点
pm2 start proxy_node.py --interpreter ./venv/bin/python3 --name tg-proxy-node
pm2 save

echo "=================================================="
echo "🎉 部署大功告成！TG Proxy 节点已经在后台稳定狂奔！"
echo "👉 你可以使用命令 'pm2 logs tg-proxy-node' 查看实时日志。"
echo "=================================================="
