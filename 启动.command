#!/bin/bash
cd "$(dirname "$0")"
# 关掉旧的
lsof -i :8866 -t 2>/dev/null | xargs kill 2>/dev/null
sleep 1
# 启动服务（后台）
python3 server.py &
# 等服务起来再开浏览器
sleep 2
open http://127.0.0.1:8866
