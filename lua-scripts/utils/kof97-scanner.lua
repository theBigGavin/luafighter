--[[
  KOF97 状态机内存扫描器
  扫描角色状态、面向、动作等关键地址
  
  使用：在 MAME 中加载此脚本后，在控制台执行：
  scan_state()     - 扫描状态地址
  scan_facing()    - 扫描面向地址
  scan_position()  - 扫描位置地址（重新扫描）
]]

local MemoryReader = require("utils.memory-reader")
local mem = MemoryReader.new()

-- 辅助：有符号读取
local function readS16(addr)
  local val = mem:readU16(addr)
  if val == nil then return nil end
  if val > 32767 then val = val - 65536 end
  return val
end

-- 扫描范围内所有非零值，按类型筛选
local function scanRegion(startAddr, endAddr, label, filter)
  print(string.format("[Scanner] %s: 0x%06X ~ 0x%06X", label, startAddr, endAddr))
  local matches = {}
  for addr = startAddr, endAddr do
    local val = mem:readU8(addr)
    if val and val ~= 0 and filter(val) then
      table.insert(matches, {addr = addr, val = val})
    end
  end
  table.sort(matches, function(a, b) return a.val > b.val end)
  print(string.format("  找到 %d 个候选", #matches))
  for i = 1, math.min(20, #matches) do
    local m = matches[i]
    print(string.format("    0x%06X = %d (0x%02X)", m.addr, m.val, m.val))
  end
end

-- 扫描 P1 区域状态机地址
function scan_state()
  print("====================================")
  print("[Scanner] KOF97 状态机扫描")
  print("说明：在战斗中运行，角色应处于可控状态")
  print("====================================")
  
  -- 扫描 P1 基础区域 0x108100-0x1082FF
  -- 寻找 0-20 之间的值（状态机通常是小值）
  scanRegion(0x108100, 0x1082FF, "P1 状态区域", function(v) 
    return v >= 0 and v <= 20 
  end)
  
  -- 扫描 P2 基础区域 0x108300-0x1084FF
  scanRegion(0x108300, 0x1084FF, "P2 状态区域", function(v) 
    return v >= 0 and v <= 20 
  end)
end

-- 扫描面向（0=左, 1=右 或类似）
function scan_facing()
  print("====================================")
  print("[Scanner] KOF97 面向扫描")
  print("说明：P1 在左侧应面向右，P2 在右侧应面向左")
  print("====================================")
  
  -- 扫描 P1 区域，寻找 0/1 值
  scanRegion(0x108100, 0x1082FF, "P1 面向", function(v) 
    return v == 0 or v == 1
  end)
end

-- 扫描位置（16-bit 有符号值）
function scan_position()
  print("====================================")
  print("[Scanner] KOF97 坐标扫描")
  print("说明：P1 在左侧应是小值，P2 在右侧应是大值")
  print("====================================")
  
  local function scanCoordRegion(startAddr, endAddr, label)
    print(string.format("[Scanner] %s", label))
    local matches = {}
    for addr = startAddr, endAddr, 2 do
      local val = readS16(addr)
      if val and val > 0 and val < 400 then
        table.insert(matches, {addr = addr, val = val})
      end
    end
    table.sort(matches, function(a, b) return a.val > b.val end)
    print(string.format("  找到 %d 个候选", #matches))
    for i = 1, math.min(15, #matches) do
      local m = matches[i]
      print(string.format("    0x%06X = %d", m.addr, m.val))
    end
  end
  
  scanCoordRegion(0x108100, 0x1082FF, "P1 坐标")
  scanCoordRegion(0x108300, 0x1084FF, "P2 坐标")
end

-- 持续监视指定地址
function watch(addr1, addr2, frames)
  frames = frames or 300
  print(string.format("[Watch] 监视 0x%06X 和 0x%06X，持续 %d 帧", addr1, addr2, frames))
  for i = 1, frames do
    if i % 10 == 0 then
      local v1 = mem:readU8(addr1) or 0
      local v2 = mem:readU8(addr2) or 0
      print(string.format("[Watch] F%d: 0x%06X=%d 0x%06X=%d", i, addr1, v1, addr2, v2))
    end
    emu.wait_frame()
  end
end

print("[KOF97 Scanner] 加载完成")
print("  scan_state()    - 扫描角色状态地址")
print("  scan_facing()   - 扫描角色面向地址")
print("  scan_position() - 扫描坐标地址")
print("  watch(addr1, addr2, frames) - 持续监视")
