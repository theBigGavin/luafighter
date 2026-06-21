--[[
  LuaFighter MAME 启动脚本
  用于 -autoboot_script 参数，执行初始设置后加载主脚本
]]

local rom = os.getenv("LUAFIGHTER_ROM") or "sf2ce"
local room = os.getenv("LUAFIGHTER_ROOM") or "room1"

-- 设置 package.path 指向项目 lua-scripts 目录
local scriptPath = debug.getinfo(1, "S").source:sub(2)
local scriptDir = scriptPath:match("(.*/)")
local projectDir = scriptDir:match("(.*/)lua%-scripts/") or scriptDir
package.path = package.path .. ";" .. projectDir .. "lua-scripts/?.lua"

-- 延迟 30 帧后加载主脚本（确保 MAME 子系统就绪）
local loadDelay = 30

emu.register_periodic(function()
  loadDelay = loadDelay - 1
  if loadDelay <= 0 then
    local ok, err = pcall(function()
      require("drivers.automation")
    end)
    if not ok then
      -- Fallback: direct dofile
      local f = io.open(projectDir .. "lua-scripts/drivers/automation.lua", "r")
      if f then
        local code = f:read("*a")
        f:close()
        local func, loadErr = load(code, "automation.lua")
        if func then
          func()
        end
      end
    end
    return false  -- 取消注册
  end
end)
