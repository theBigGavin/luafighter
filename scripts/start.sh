#!/bin/bash
set -e

echo "========================================"
echo "LuaFighter 一键启动脚本"
echo "========================================"

# 检查依赖
command -v docker >/dev/null 2>&1 || { echo "错误: 需要安装 Docker"; exit 1; }
command -v docker-compose >/dev/null 2>&1 || { echo "错误: 需要安装 docker-compose"; exit 1; }

# 检查 ROM 目录
if [ ! -d "roms" ]; then
  echo "创建 ROM 目录..."
  mkdir -p roms
  echo "⚠️  请将自己的 ROM 文件放入 roms/ 目录"
fi

cd docker

echo "构建并启动服务..."
docker-compose up --build -d

echo ""
echo "========================================"
echo "服务启动完成!"
echo "========================================"
echo ""
echo "前端界面: http://localhost"
echo "管理器 API: http://localhost:9003"
echo "行情服务: ws://localhost:9001"
echo "MediaMTX: http://localhost:8889"
echo ""
echo "查看日志: docker-compose logs -f"
echo "停止服务: docker-compose down"
echo ""
