#!/bin/bash
# LuaFighter 内存校准启动脚本
# 用法: ./scripts/calibrate.sh <rom-name>
# 示例: ./scripts/calibrate.sh sf2ce
set -e
source ~/.zshrc 2>/dev/null || true
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ROM="${1:-sf2ce}"

# 检查 ROM
if [ ! -f "$PROJECT_DIR/roms/${ROM}.zip" ]; then
  echo "❌ ROM 文件不存在: roms/${ROM}.zip"
  exit 1
fi

# 清理旧日志
rm -f /tmp/luafighter-calibration.log
export LUAFIGHTER_ROM="$ROM"
export LUAFIGHTER_ROOM="${LUAFIGHTER_ROOM:-calibration}"
export LUAFIGHTER_DRIVER="calibration"

echo "=== LuaFighter 内存校准 ==="
echo "ROM: ${ROM}"
echo "输出: /tmp/luafighter-calibration.log"
echo ""

mame "$ROM" \
  -window \
  -rompath "$PROJECT_DIR/roms" \
  -pluginspath "$PROJECT_DIR/plugins" \
  -plugin luafighter \
  -sound none \
  2>&1

echo ""
echo "校准完成!"
echo "查看完整日志: cat /tmp/luafighter-calibration.log"
echo "快速查看状态变化: grep '状态变化' /tmp/luafighter-calibration.log"
echo "查看血量候选: grep '可能血量' /tmp/luafighter-calibration.log | head -50"
