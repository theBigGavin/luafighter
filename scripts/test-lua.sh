#!/bin/bash
# LuaFighter 便捷启动脚本
set -e

ROM="${1:-sf2ce}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 检查依赖
if ! command -v mame >/dev/null 2>&1; then
  echo "❌ 错误: MAME 未安装"
  exit 1
fi
if [ ! -f "$PROJECT_DIR/roms/${ROM}.zip" ]; then
  echo "❌ 错误: ROM 文件不存在: $PROJECT_DIR/roms/${ROM}.zip"
  exit 1
fi

export LUAFIGHTER_ROM="$ROM"
export LUAFIGHTER_ROOM="${LUAFIGHTER_ROOM:-room1}"
export LUAFIGHTER_DRIVER="${LUAFIGHTER_DRIVER:-automation}"

# 检测 ROM 是否需要 Universe BIOS (KOF97)
BIOS_ARG=""
if [ "$ROM" = "kof97" ]; then
  BIOS_ARG="-bios unibios40"
  echo "ℹ️  KOF97 使用 Universe BIOS 以支持 1P vs 2P"
fi

echo ""
echo "LuaFighter 启动: ROM=$ROM rompath=$PROJECT_DIR/roms $BIOS_ARG"
echo ""

mame "$ROM" \
  -window \
  -rompath "$PROJECT_DIR/roms" \
  -pluginspath "$PROJECT_DIR/plugins" \
  -plugin luafighter \
  $BIOS_ARG \
  -sound none \
  -nothrottle \
  -seconds_to_run 70 \
  2>&1

echo ""
echo "===== 调试日志 ====="
cat /tmp/luafighter-debug.log 2>/dev/null
echo ""
echo "===== 投币结果 ====="
grep -E "开始注入|响应输入|Phase=fight|KOF97 Entry|battle signals" /tmp/luafighter-debug.log 2>/dev/null || echo "(未检测到进场)"
