-- verify-addresses.lua
-- KOF97 关键地址验证脚本
-- 用法：在 MAME 中运行，观察屏幕上打印的内存值

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local s = manager.machine.screens[":screen"]

-- 要验证的地址
local addresses = {
  -- 血量（已修正为 Cheat Database 地址）
  { addr = 0x108239, name = "P1_HP",     type = "u8" },
  { addr = 0x108439, name = "P2_HP",     type = "u8" },
  -- 坐标（来自逆向工程资料，需验证）
  { addr = 0x108180, name = "P1_X_DWord", type = "u32" },
  { addr = 0x108380, name = "P2_X_DWord", type = "u32" },
  { addr = 0x108186, name = "P1_Y_DWord", type = "u32" },
  { addr = 0x108386, name = "P2_Y_DWord", type = "u32" },
  -- 相邻地址（用于确认数据宽度）
  { addr = 0x108238, name = "P1_HP_prev", type = "u8" },
  { addr = 0x108240, name = "P1_HP_next", type = "u8" },
  -- 状态（需验证）
  { addr = 0x10815A, name = "P1_State",  type = "u16" },
  { addr = 0x10835A, name = "P2_State",  type = "u16" },
  -- 朝向
  { addr = 0x10810D, name = "P1_Face",   type = "u8" },
  { addr = 0x10830D, name = "P2_Face",   type = "u8" },
  -- 时间
  { addr = 0x10A83A, name = "Time",      type = "u8" },
}

local frame = 0

function drawOverlay()
  frame = frame + 1
  
  local y = 10
  local lineHeight = 10
  
  s:draw_text(10, y, string.format("=== KOF97 Address Verification (F%d) ===", frame), 0xFFFFFF00)
  y = y + lineHeight + 2
  
  for _, entry in ipairs(addresses) do
    local val
    if entry.type == "u8" then
      val = mem:read_u8(entry.addr)
    elseif entry.type == "u16" then
      val = mem:read_u16(entry.addr)
    elseif entry.type == "u32" then
      val = mem:read_u32(entry.addr)
    end
    
    local text = string.format("%s (0x%06X) [%s]: %d (0x%02X)", 
      entry.name, entry.addr, entry.type, val, val)
    s:draw_text(10, y, text, 0xFFFFFFFF)
    y = y + lineHeight
  end
  
  -- 额外信息：P1/P2 距离
  local x1 = mem:read_u32(0x108180)
  local x2 = mem:read_u32(0x108380)
  s:draw_text(10, y, string.format("Distance: |%d - %d| = %d", x1, x2, math.abs(x1 - x2)), 0xFF00FF00)
end

emu.register_frame_done(drawOverlay, "frame")
print("KOF97 Address Verification Overlay installed. Press F5 to run.")
