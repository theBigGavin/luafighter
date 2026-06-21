--[[
  LuaFighter 内存校准脚本
  用途：扫描 CPS1 SF2CE 工作 RAM，找出正确的游戏状态、血量、位置地址
  用法: 通过 test-lua.sh 加载，或直接 mame sf2ce -autoboot_script 加载
  
  输出: /tmp/luafighter-calibration.log
]]

local CALIB_LOG = "/tmp/luafighter-calibration.log"
local logFile = io.open(CALIB_LOG, "w")

local function log(msg)
  if logFile then
    logFile:write(tostring(msg) .. "\n")
    logFile:flush()
  end
  print(msg)
end

log("=== CPS1 SF2CE 内存校准 ===")
log("MAME: " .. emu.app_name() .. " " .. emu.app_version())
log("ROM: sf2ce")

-- 获取 68000 program space
local maincpu = manager.machine and manager.machine.devices[":maincpu"]
if not maincpu then
  log("错误: 找不到 :maincpu")
  return  -- MAME environment, can't exit
end
local space = maincpu.spaces and maincpu.spaces["program"]
if not space then
  log("错误: 找不到 program space")
  return  -- MAME environment, can't exit
end

local frameCount = 0
-- 用于第一次 dump 的标记
local dumpedAttract = false
local dumpedTitle = false
local dumpedAfterCoin = false
local coinInjected = false
local prevState = 0xFF

-- 要扫描的候选地址
-- 这些是根据 MAME CPS1 驱动 + 社区经验整理的常见地址
local SCAN_RANGES = {
  -- 游戏状态区域
  { name = "GAME_STATE_1",  start = 0xFF8A80, ["end"] = 0xFF8B40 },
  { name = "GAME_STATE_2",  start = 0xFF8CB0, ["end"] = 0xFF8D00 },
  { name = "GAME_STATE_3",  start = 0xFF9C00, ["end"] = 0xFF9D00 },
  -- 血量区域
  { name = "HEALTH_1",      start = 0xFF0000, ["end"] = 0xFF0200 },
  { name = "HEALTH_2",      start = 0xFF0A00, ["end"] = 0xFF0B00 },
  { name = "HEALTH_3",      start = 0xFF2F00, ["end"] = 0xFF3000 },
  { name = "HEALTH_4",      start = 0xFF8C70, ["end"] = 0xFF8CD0 },
  { name = "HEALTH_5",      start = 0xFF9CE0, ["end"] = 0xFF9D20 },
  -- 位置区域
  { name = "POS_1",         start = 0xFF8400, ["end"] = 0xFF8600 },
  { name = "POS_2",         start = 0xFF8700, ["end"] = 0xFF8900 },
  { name = "POS_3",         start = 0xFF8C80, ["end"] = 0xFF8CD0 },
  { name = "POS_4",         start = 0xFF8CC0, ["end"] = 0xFF8D00 },
}

-- 从空间读取一个字节
local function r8(addr)
  local ok, v = pcall(function() return space:read_u8(addr) end)
  return ok and v or -1
end

-- 从空间读取一个字（16位，大端）
local function r16(addr)
  local hi = r8(addr)
  local lo = r8(addr + 1)
  if hi >= 0 and lo >= 0 then
    return hi * 256 + lo
  end
  return -1
end

-- 转换 addr 到十六进制字符串
local function hex(addr)
  return string.format("0x%06X", addr)
end

-- 安装 CPS1 read taps
local function installTaps()
  -- IN1 @ 0x800000-0x800007
  local ok1, err1 = pcall(function()
    return space:install_read_tap(0x800000, 0x800007, "calib_in1", function(offset, data, mask)
      return data
    end)
  end)

  -- IN0 @ 0x800018-0x80001F
  local ok2, err2 = pcall(function()
    return space:install_read_tap(0x800018, 0x80001f, "calib_in0", function(offset, data, mask)
      if offset ~= 0x800018 and offset ~= 0x80001A then
        return data
      end
      return data
    end)
  end)

  if ok1 and ok2 then
    log("[校准] CPS1 taps 已安装")
    return true
  end
  log("[校准] taps 安装失败: " .. tostring(err1) .. " / " .. tostring(err2))
  return false
end

-- 扫描一个完整的范围
local function scanRange(name, startAddr, endAddr)
  log(string.format("\n--- %s (%s-%s) ---", name, hex(startAddr), hex(endAddr)))
  local buf = {}
  local count = 0
  for addr = startAddr, endAddr do
    local v = r8(addr)
    if v >= 0 then
      buf[#buf + 1] = string.format("%02X", v)
      count = count + 1
      if #buf >= 16 then
        log(string.format("0x%06X: %s", addr - 15, table.concat(buf, " ")))
        buf = {}
      end
    end
  end
  if #buf > 0 then
    log(string.format("0x%06X: %s", endAddr - #buf + 1, table.concat(buf, " ")))
  end
  log(string.format("(%d 字节)", count))
end

-- 扫描候选地址
local function scanCandidates()
  log("\n=== 帧 " .. frameCount .. " 内存扫描 ===")
  
  -- 1. 核心候选地址
  log("\n--- 核心候选 ---")
  local coreAddrs = {
    0xFF004F, 0xFF008F,  -- 原 P1/P2 血量
    0xFF0AAC, 0xFF0AEE,  -- 社区常见血量地址
    0xFF8ABF, 0xFF8ACF,  -- 原状态地址
    0xFF8C7E, 0xFF8CBE,  -- 社区常见血量
    0xFF8C80, 0xFF8CC0,  -- 社区常见位置
    0xFF8450, 0xFF8750,  -- 原 P1/P2 X 位置
    0xFF2F4F, 0xFF2F8F,  -- 其他常见血量
    0xFF9CEF,            -- CPS2 风格（验证用）
    0xFF0F4F, 0xFF0F8F,  -- 其他
  }
  
  for _, addr in ipairs(coreAddrs) do
    local v = r8(addr)
    local v16 = r16(addr)
    log(string.format("[核心] %s = 0x%02X (u8) 0x%04X (u16)", hex(addr), v, v16))
  end
  
  -- 2. 检测血量：找 0-240 范围内且相邻地址值相似的模式
  log("\n--- 血量扫描 (0xFF0000-0xFF0FFF) ---")
  -- 先扫描整个健康区域并记录可能的值
  local healthCandidates = {}
  for addr = 0xFF0000, 0xFF0FFF do
    local v = r8(addr)
    if v and v > 0 and v <= 240 then
      healthCandidates[#healthCandidates + 1] = { addr = addr, val = v }
    end
  end
  -- 只输出前 100 个可能的
  local maxOut = math.min(100, #healthCandidates)
  for i = 1, maxOut do
    local c = healthCandidates[i]
    log(string.format("[可能血量] %s = %d", hex(c.addr), c.val))
  end
  if #healthCandidates > 100 then
    log(string.format("... (共 %d 个候选, 仅显示前 100)", #healthCandidates))
  end
  
  -- 3. 全范围扫描选定的区域
  for _, range in ipairs(SCAN_RANGES) do
    scanRange(range.name, range.start, range["end"])
  end
end

-- 安装 taps
installTaps()

-- 主循环
emu.register_periodic(function()
  frameCount = frameCount + 1

  -- 状态地址
  local stateVal = r8(0xFF8ABF)
  
  -- 每 300 帧（约5秒）记录一次核心信息
  if frameCount % 300 == 0 then
    local p1hp = r8(0xFF004F)
    local p2hp = r8(0xFF008F)
    local p1hp2 = r8(0xFF8C7E)
    local p2hp2 = r8(0xFF8CBE)
    log(string.format("[帧%05d] state=0x%02X p1hp=%d/%d p2hp=%d/%d p1hp2=%d p2hp2=%d",
      frameCount, stateVal,
      p1hp, r8(0xFF008F), p2hp, r8(0xFF0AAC),
      p1hp2, p2hp2))

    -- 状态变化检测
    if stateVal ~= prevState then
      log(string.format(">>> 状态变化: 0x%02X -> 0x%02X @ 帧 %d", prevState, stateVal, frameCount))
      prevState = stateVal
      
      -- 状态变化时做一次深度扫描
      scanCandidates()
    end
  end

  -- 注入投币（帧2100时）
  if frameCount == 2100 and not coinInjected then
    coinInjected = true
    log("\n=== 注入投币/Start @ 帧2100 ===")
    
    -- 手动修改 tap 状态 (直接写地址测试)
    -- 在 IN1 tap 中注入 P1 Start
    local ok, err = pcall(function()
      space:install_read_tap(0x800018, 0x80001f, "calib_inject", function(offset, data, mask)
        if offset ~= 0x800018 and offset ~= 0x80001A then
          return data
        end
        -- active-low: 清除 bit4 (P1 Start) 和 bit0 (P1 Coin)
        -- 数据格式: cps1_dsw_r 返回 (ioport("IN0")->read() << 8) | 0xff
        -- 所以 IN0 在高字节
        local modified = data
        -- 先投币: 清除 bit0<<8 = 0x0100
        modified = modified & ~0x0100
        return modified
      end)
    end)
    if ok then
      log("[校准] 投币 tap 已安装")
    else
      log("[校准] 投币 tap 安装失败: " .. tostring(err))
    end

    -- 先做一次扫描
    scanCandidates()
  end
  
  -- 投币后 120 帧按 Start
  if frameCount == 2220 then
    log("\n=== 按 Start @ 帧2220 ===")
    -- 因为上面已经装了 tap，这里重新安装同时清除 bit4 (P1 Start)
    local ok, err = pcall(function()
      space:install_read_tap(0x800018, 0x80001f, "calib_inject2", function(offset, data, mask)
        if offset ~= 0x800018 and offset ~= 0x80001A then
          return data
        end
        local modified = data
        -- Coin + Start: 清除 bit0<<8 + bit4<<8 = 0x0100 + 0x1000 = 0x1100
        modified = modified & ~0x1100
        return modified
      end)
    end)
  end
  
  -- 投币后每 300 帧做一次完整扫描
  if coinInjected and frameCount > 2220 and frameCount % 300 == 0 then
    scanCandidates()
  end

  -- 60 秒后自动退出
  if frameCount > 3600 then
    log("\n=== 校准完成 (3600帧 = 60秒) ===")
    if logFile then logFile:close() end
    emu.pause()
  end
end)

log("[校准] 脚本已加载，开始监控帧循环...")
log("  帧 2100: 投币")
log("  帧 2220: 按 Start")
log("  帧 3600: 自动停止")
log("输出: " .. CALIB_LOG)
