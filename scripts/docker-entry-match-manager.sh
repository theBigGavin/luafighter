#!/bin/bash
# Docker 入口脚本：match-manager
# 负责启动 Xvfb、PulseAudio 并构造 MAME 可用的合并插件目录
set -e

# 1. 虚拟显示
mkdir -p /tmp/.X11-unix /tmp/pulse
rm -f /tmp/.X11-unix/X99 /tmp/.X99-lock /tmp/pulse/pid /tmp/pulse/native
Xvfb :99 -ac -screen 0 640x480x24 &

# 2. PulseAudio null sink
PULSE_RUNTIME_PATH=/tmp/pulse pulseaudio --start --exit-idle-time=-1
sleep 1
PULSE_RUNTIME_PATH=/tmp/pulse pactl load-module module-null-sink sink_name=luafighter sink_properties=device.description=LuaFighter >/dev/null || true

# 3. 构造合并插件目录
# MAME 0.288 的插件发现机制要求插件位于包含 boot.lua / plugin.schema 的同一根目录下，
# 仅通过 -pluginspath 指向自定义目录会导致插件无法加载。因此把系统插件目录复制到 /tmp，
# 再把项目自定义插件（主要是 luafighter）覆盖进去。
SYSTEM_PLUGINS="/usr/share/games/mame/plugins"
CUSTOM_PLUGINS="/app/plugins"
MERGED_PLUGINS="/tmp/mame-plugins"

rm -rf "$MERGED_PLUGINS"
if [ -d "$SYSTEM_PLUGINS" ]; then
  cp -r "$SYSTEM_PLUGINS" "$MERGED_PLUGINS"
else
  mkdir -p "$MERGED_PLUGINS"
fi

if [ -d "$CUSTOM_PLUGINS" ]; then
  cp -r "$CUSTOM_PLUGINS"/* "$MERGED_PLUGINS"/ 2>/dev/null || true
fi

chmod -R u+w "$MERGED_PLUGINS" 2>/dev/null || true

export DISPLAY=:99
export PULSE_SINK=luafighter
export PULSE_RUNTIME_PATH=/tmp/pulse
export PULSE_SERVER=unix:/tmp/pulse/native
export PLUGIN_PATH="$MERGED_PLUGINS"
export LUAFIGHTER_PATH=/app

echo "[match-manager-entry] 合并插件目录: $MERGED_PLUGINS"
echo "[match-manager-entry] 启动 match-manager..."

exec node packages/match-manager/dist/index.js
