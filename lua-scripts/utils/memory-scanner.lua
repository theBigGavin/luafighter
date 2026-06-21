--[[
  LuaFighter 内存地址扫描工具
  辅助定位 MAME 游戏中关键内存地址
  
  使用方法：
  mame sf2ce -window -lua lua-scripts/utils/memory-scanner.lua
  
  然后在 MAME 控制台中输入以下命令：
  scan_health()   - 扫描血量地址
  scan_state()    - 扫描游戏状态地址
  scan_position() - 扫描坐标地址
  
  扫描结果会输出到 MAME 控制台，将正确的地址填入 rom-configs/*.json
]]

local MemoryReader = require("memory-reader")

local mem = MemoryReader.new()

-- ============ 通用扫描函数 ============

-- 扫描范围内变化的字节值
local function scanRange(startAddr, endAddr, expectedValue, tolerance, label)
  print(string.format("[Scanner] 扫描 %s: 0x%06X ~ 0x%06X, 期望值: %d (容差: %d)",
    label, startAddr, endAddr, expectedValue, tolerance))
  
  local matches = {}
  for addr = startAddr, endAddr do
    local val = mem:readU8(addr)
    if math.abs(val - expectedValue) <= tolerance then
      table.insert(matches, { addr = addr, value = val })
    end
  end
  
  print(string.format("[Scanner] 找到 %d 个匹配地址", #matches))
  
  -- 只打印前 20 个
  for i = 1, math.min(20, #matches) do
    local m = matches[i]
    print(string.format("  0x%06X = %d", m.addr, m.value))
  end
  
  if #matches > 20 then
    print(string.format("  ... 还有 %d 个匹配", #matches - 20))
  end
  
  return matches
end

-- 两阶段扫描：先大范围搜索，再精确验证
local function twoPhaseScan(startAddr, endAddr, value1, value2, label)
  print(string.format("[Scanner] 两阶段扫描 %s", label))
  print(string.format("  阶段1: 搜索值 %d", value1))
  
  local phase1 = scanRange(startAddr, endAddr, value1, 0, label .. "_phase1")
  
  if #phase1 == 0 then
    print("[Scanner] 阶段1 无匹配，扩大容差重试")
    phase1 = scanRange(startAddr, endAddr, value1, 5, label .. "_phase1_retry")
  end
  
  if #phase1 == 0 then
    print("[Scanner] 阶段1 仍无匹配，请确认游戏状态正确")
    return {}
  end
  
  print(string.format("[Scanner] 阶段2: 验证值变为 %d (请等待...)", value2))
  print("[Scanner] 提示: 按 Enter 继续，或等待 5 秒后自动继续")
  
  -- 等待用户操作
  local waited = 0
  while waited < 500 do
    emu.wait_frame()
    waited = waited + 1
  end
  
  local phase2 = {}
  for _, m in ipairs(phase1) do
    local val = mem:readU8(m.addr)
    if val == value2 or math.abs(val - value2) <= 2 then
      table.insert(phase2, m)
    end
  end
  
  print(string.format("[Scanner] 阶段2 后剩余 %d 个候选地址", #phase2))
  for i = 1, math.min(10, #phase2) do
    local m = phase2[i]
    print(string.format("  0x%06X = %d", m.addr, m.value))
  end
  
  return phase2
end

-- ============ 专用扫描函数 ============

function scan_health()
  print("====================================")
  print("[Scanner] 血量地址扫描")
  print("说明：请确保当前游戏中双方血量满值")
  print("====================================")
  
  -- 街霸2 满血量通常为 176 (0xB0)
  -- 扫描 CPS-1 常见内存区域
  local maxHealth = 176
  local candidates = scanRange(0xFF8000, 0xFF9000, maxHealth, 2, "P1血量(满值)")
  
  print("")
  print("[Scanner] 建议：")
  print("  1. 进入对战，让1P受一点伤害")
  print("  2. 再次运行 scan_health()")
  print("  3. 比较两次结果，找出地址变化的即为血量地址")
  
  return candidates
end

function scan_health_after_damage()
  print("====================================")
  print("[Scanner] 血量地址扫描（受伤后）")
  print("说明：请确保1P已受伤，血量低于满值")
  print("====================================")
  
  -- 扫描非满值的血量
  local candidates = {}
  for addr = 0xFF8000, 0xFF9000 do
    local val = mem:readU8(addr)
    if val > 0 and val < 170 then  -- 不是满值也不是0
      table.insert(candidates, { addr = addr, value = val })
    end
  end
  
  print(string.format("[Scanner] 找到 %d 个可能地址", #candidates))
  for i = 1, math.min(20, #candidates) do
    local m = candidates[i]
    print(string.format("  0x%06X = %d", m.addr, m.value))
  end
  
  return candidates
end

function scan_state()
  print("====================================")
  print("[Scanner] 游戏状态地址扫描")
  print("说明：需要在不同状态（标题/选人/对战）下分别运行")
  print("====================================")
  
  -- 扫描可能的系统状态区域
  -- 街霸2 的状态通常在一个区域内变化
  local candidates = {}
  for addr = 0xFF8000, 0xFF8100 do
    local val = mem:readU8(addr)
    -- 状态值通常较小（0-255 的低端）
    if val <= 20 then
      table.insert(candidates, { addr = addr, value = val })
    end
  end
  
  print(string.format("[Scanner] 找到 %d 个低值地址（可能的状态字节）", #candidates))
  for i = 1, math.min(30, #candidates) do
    local m = candidates[i]
    print(string.format("  0x%06X = %d", m.addr, m.value))
  end
  
  print("")
  print("[Scanner] 建议：")
  print("  1. 记录当前状态和各地址的值")
  print("  2. 切换游戏状态（如进入选人）")
  print("  3. 再次运行，找出变化的地址")
  print("  4. 常用街霸2状态值：0x00=标题, 0x10=选人, 0x20=对战")
  
  return candidates
end

function scan_position()
  print("====================================")
  print("[Scanner] 坐标地址扫描")
  print("说明：请确保1P在画面左侧，2P在右侧")
  print("====================================")
  
  -- 坐标通常是 16 位有符号值
  local candidates = {}
  for addr = 0xFF8000, 0xFF9000, 2 do  -- 步进2，因为坐标是16位
    local val = mem:readS16(addr)
    -- 1P 在左侧 -> 小值，2P 在右侧 -> 大值
    if val >= 0 and val <= 500 then
      table.insert(candidates, { addr = addr, value = val })
    end
  end
  
  print(string.format("[Scanner] 找到 %d 个可能坐标地址", #candidates))
  for i = 1, math.min(20, #candidates) do
    local m = candidates[i]
    print(string.format("  0x%06X = %d", m.addr, m.value))
  end
  
  print("")
  print("[Scanner] 建议：")
  print("  1. 让1P向右移动")
  print("  2. 再次扫描，找出值变大的地址")
  print("  3. 该地址即为 P1 X 坐标")
  
  return candidates
end

-- 连续扫描模式（自动追踪变化）
function watch_addresses(addresses, durationFrames)
  durationFrames = durationFrames or 300
  print(string.format("[Scanner] 开始监视 %d 个地址，持续 %d 帧", #addresses, durationFrames))
  
  for i = 1, durationFrames do
    if i % 10 == 0 then
      local line = string.format("[Watch] Frame %d: ", i)
      for _, addr in ipairs(addresses) do
        local val = mem:readU8(addr)
        line = line .. string.format("0x%06X=%d ", addr, val)
      end
      print(line)
    end
    emu.wait_frame()
  end
  
  print("[Scanner] 监视结束")
end

print("[MemoryScanner] 内存扫描工具已加载")
print("[MemoryScanner] 可用命令：")
print("  scan_health()           - 扫描血量地址")
print("  scan_health_after_damage() - 受伤后扫描")
print("  scan_state()            - 扫描游戏状态地址")
print("  scan_position()         - 扫描坐标地址")
print("  watch_addresses({addr1, addr2}, frames) - 持续监视地址变化")
print("")
print("[MemoryScanner] 使用示例：")
print("  1. 确保游戏在1P满血状态下")
print("  2. 在 MAME 控制台输入: scan_health()")
print("  3. 让1P受伤，再输入: scan_health_after_damage()")
print("  4. 对比结果，找出血量地址")
