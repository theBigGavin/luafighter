-- LuaFighter MAME 插件入口
local exports = {}
exports.name = "luafighter"
exports.version = "1.0.0"
exports.description = "LuaFighter automation plugin"
exports.license = "MIT"

function exports.startplugin()
  -- 根据环境变量或本文件位置动态推导项目 lua-scripts 目录
  -- 例如 /app/plugins/luafighter/init.lua -> /app/lua-scripts
  local projectDir = os.getenv("LUAFIGHTER_PATH") or ""
  if projectDir == "" then
    local source = debug.getinfo(1, "S").source
    if source and source:sub(1, 1) == "@" then
      source = source:sub(2)
    end
    local pluginFileDir = source:match("(.*/)") or ""
    projectDir = pluginFileDir:match("(.*/)plugins/") or pluginFileDir:match("(.*/)lua%-scripts/") or ""
  end
  if projectDir ~= "" and projectDir:sub(-1) ~= "/" then
    projectDir = projectDir .. "/"
  end
  local luaScriptsDir = projectDir .. "lua-scripts"

  package.path = package.path .. ";" .. luaScriptsDir .. "/?.lua"
  local driverName = os.getenv("LUAFIGHTER_DRIVER") or "automation"

  print("[LuaFighter] 插件已加载，准备加载自动化脚本...")
  print("[LuaFighter] lua-scripts 路径: " .. luaScriptsDir)
  print("[LuaFighter] driver: " .. driverName)

  -- 加载主自动化脚本
  local ok, err = pcall(function()
    local script = require("drivers." .. driverName)
  end)
  if not ok then
    print("[LuaFighter] 加载 driver 失败:", err)
    -- 尝试直接加载文件
    local f = io.open(luaScriptsDir .. "/drivers/" .. driverName .. ".lua", "r")
    if f then
      local code = f:read("*a")
      f:close()
      local func, loadErr = load(code, driverName .. ".lua")
      if func then
        func()
        print("[LuaFighter] " .. driverName .. ".lua 通过 load() 加载成功")
      else
        print("[LuaFighter] load() 失败:", loadErr)
      end
    else
      print("[LuaFighter] 无法打开 " .. driverName .. ".lua")
    end
  end
end

return exports
