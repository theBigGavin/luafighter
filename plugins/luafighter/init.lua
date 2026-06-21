-- LuaFighter MAME 插件入口
local exports = {}
exports.name = "luafighter"
exports.version = "1.0.0"
exports.description = "LuaFighter automation plugin"
exports.license = "MIT"

function exports.startplugin()
  -- 设置 Lua 搜索路径，指向项目 lua-scripts 目录
  local pluginDir = "/Users/gavin/playground/gameplay/luafighter/lua-scripts"
  package.path = package.path .. ";" .. pluginDir .. "/?.lua"

  print("[LuaFighter] 插件已加载，准备加载自动化脚本...")

  -- 加载主自动化脚本
  local ok, err = pcall(function()
    local script = require("drivers.automation")
  end)
  if not ok then
    print("[LuaFighter] 加载 automation.lua 失败:", err)
    -- 尝试直接加载文件
    local f = io.open(pluginDir .. "/drivers/automation.lua", "r")
    if f then
      local code = f:read("*a")
      f:close()
      local func, loadErr = load(code, "automation.lua")
      if func then
        func()
        print("[LuaFighter] automation.lua 通过 load() 加载成功")
      else
        print("[LuaFighter] load() 失败:", loadErr)
      end
    else
      print("[LuaFighter] 无法打开 automation.lua")
    end
  end
end

return exports
