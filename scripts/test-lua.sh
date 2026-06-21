#!/bin/bash
# LuaFighter 便捷启动脚本
set -e

ROM="${1:-sf2ce}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BOOT_SCRIPT="/tmp/luafighter-boot.lua"

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

# 创建 boot 脚本
cat > "$BOOT_SCRIPT" << EOF
package.path = package.path .. ";$PROJECT_DIR/lua-scripts/?.lua"
local ok, err = pcall(function()
  require("drivers.automation")
end)
if not ok then
  local fd = io.open("/tmp/luafighter-boot-error.log", "w")
  if fd then fd:write(tostring(err) .. "\n"); fd:close() end
end
EOF

echo "✅ 启动脚本已创建: $BOOT_SCRIPT"
echo ""
echo "LuaFighter 启动: ROM=$ROM rompath=$PROJECT_DIR/roms"
echo ""

mame "$ROM" \
  -window \
  -rompath "$PROJECT_DIR/roms" \
  -autoboot_script "$BOOT_SCRIPT" \
  -sound none \
  -nothrottle \
  -seconds_to_run 70 \
  2>&1

echo ""
echo "===== 调试日志 ====="
cat /tmp/luafighter-debug.log 2>/dev/null
echo ""
echo "===== 投币结果 ====="
grep -E "开始注入|响应输入|Phase=fight" /tmp/luafighter-debug.log 2>/dev/null || echo "(未检测到投币)"
