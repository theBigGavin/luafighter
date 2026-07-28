-- LuaFighter 插件引导脚本（替代 MAME 自带的 plugins/boot.lua）
--
-- 背景：MAME 0.288 的 start_luaengine() 只负责扫描 plugin.json 和设置
-- start 标志，真正加载 init.lua 并调用 startplugin() 的是 pluginspath
-- 根目录下的 boot.lua。使用自定义 -pluginspath 会替换 MAME 安装目录下
-- 的 plugins 路径，如果这里没有 boot.lua，-plugin 指定的插件会被注册
-- 但永远不会启动，且不报任何错误（静默失败）。

_G.emu.plugin = _G.emu.plugin or {}

-- 将 pluginspath 加入 Lua 模块搜索路径，使 require(<name>) 能找到
-- <pluginspath>/<name>/init.lua
local dirs = manager.options.entries.pluginspath:value()
for dir in string.gmatch(dirs, "([^;]+)") do
  package.path = package.path .. ";" .. dir .. "/?.lua;" .. dir .. "/?/init.lua"
end

for _, entry in pairs(manager.plugins) do
  if entry.type == "plugin" and entry.start then
    emu.print_verbose("Starting plugin " .. entry.name .. "...")
    local ok, err = pcall(function()
      local plugin = require(entry.name)
      if plugin.set_folder ~= nil then plugin.set_folder(entry.directory) end
      plugin.startplugin()
    end)
    if not ok then
      -- 单个插件启动失败不应拖垮整个模拟器，但必须可见（fail-fast 日志）
      print("[LuaFighter] 插件 " .. entry.name .. " 启动失败: " .. tostring(err))
    end
  end
end
