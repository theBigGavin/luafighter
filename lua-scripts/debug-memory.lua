-- LuaFighter 内存地址调试验证脚本
-- 在 MAME 中运行，每帧打印关键内存地址的值

local function hexToNum(hexStr)
  if type(hexStr) == "number" then return hexStr end
  if type(hexStr) == "string" then
    return tonumber(hexStr:gsub("0x", ""), 16)
  end
  return 0
end

local function readU8(addr)
  addr = hexToNum(addr)
  local machine = manager.machine
  if not machine then return 0 end
  local dev = machine.devices[":maincpu"]
  if not dev then return 0 end
  local space = dev.spaces and dev.spaces["program"]
  if space and space.read_u8 then
    return space:read_u8(addr) or 0
  end
  return 0
end

local function readS16(addr)
  addr = hexToNum(addr)
  local lo = readU8(addr)
  local hi = readU8(addr + 1)
  local val = lo + hi * 256
  if val > 32767 then val = val - 65536 end
  return val
end

local frame = 0
local lastState = -1
local lastP1Hp = -1
local lastP2Hp = -1

emu.register_periodic(function()
  frame = frame + 1
  
  local state = readU8("0xFF8ABF")
  local p1Hp = readU8("0xFF83E8")
  local p2Hp = readU8("0xFF86E8")
  local p1X = readS16("0xFF8450")
  local p2X = readS16("0xFF8750")
  local p1Char = readU8("0xFF864E")
  local p2Char = readU8("0xFF894E")
  
  -- 只在值变化时打印（减少输出量）
  if state ~= lastState or p1Hp ~= lastP1Hp or p2Hp ~= lastP2Hp or frame % 60 == 0 then
    print(string.format("[Debug] Frame=%d State=0x%02X P1HP=%d P2HP=%d P1X=%d P2X=%d P1Char=%d P2Char=%d",
      frame, state, p1Hp, p2Hp, p1X, p2X, p1Char, p2Char))
    lastState = state
    lastP1Hp = p1Hp
    lastP2Hp = p2Hp
  end
  
  -- 60秒后自动退出
  if frame >= 3600 then
    print("[Debug] 60秒到达，退出")
    emu.exit()
  end
end)

print("[Debug] 内存地址验证脚本已加载")
print("[Debug] 每帧监视以下地址:")
print("  0xFF8ABF = 游戏状态")
print("  0xFF83E8 = P1 血量")
print("  0xFF86E8 = P2 血量")
print("  0xFF8450 = P1 X 坐标")
print("  0xFF8750 = P2 X 坐标")
print("  0xFF864E = P1 角色")
print("  0xFF894E = P2 角色")
print("[Debug] 60秒后自动退出")
