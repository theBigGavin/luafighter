--[[
  LuaFighter 输入控制器封装
  管理虚拟手柄状态，支持按键组合、连招序列
  针对 MAME 0.288 API 优化

  CPS1 输入注入方案（已实测验证有效）:
  ──────────────────────────────────────────
  MAME 0.288 的 CPS1 架构中 ioport field:set_value()
  对内存映射 I/O（0x800000 区域）不生效，因为 CPS1 使用 IP_ACTIVE_LOW
  而 set_value() 的 m_digital_value 机制不兼容 active-low 端口。

  已验证方案：使用 install_read_tap() 直接在 68000 内存读路径上
  修改 I/O 返回数据 (active-low = 按位清除)。

  通过 MAME 0.288 实测确认的关键信息:
  1. TAP 回调中绝对不能调用 print() / io.open() 等 I/O 操作！
     MAME 在内存读取路径的上下文中执行回调，I/O 操作会导致错误并禁用 tap。
     表现为 tap 前几次调用正常，后续被静默停用。
  2. 游戏在 attract demo（CPU对战演示，约25-30秒）期间不检测输入。
     必须等待 demo 结束后回到标题画面才开始检测按键。
  3. cps1_dsw_r 对 0x800018 和 0x80001A 返回相同的 IN0 值，
     但 0x80001C 和 0x80001E 是 DSWB/DSWC（不同的 I/O 端口），不能修改。
  4. 0x800000-0x800001 返回 IN1（玩家方向/拳按钮），每帧约读2次。
  5. CPS-B (0x800176) 每帧读1次用于保护检测，不包含按钮输入。

  CPS1 内存映射 (SF2CE):
    0x800000-0x800007 -> portr("IN1")   16-bit 玩家控制 (P1低8位+P2高8位)
    0x800018          -> cps1_dsw_r     IN0 系统按钮 (投币/开始) 在返回值高字节
    0x800030          -> cps1_coin_w    投币计数器/锁存器写入
    0x800140-0x80017f -> CPS-B          保护芯片寄存器（每帧读一次 0x800176）

  Neo Geo 输入注入方案（KOF97 实测有效）:
  ──────────────────────────────────────────
  Neo Geo 的 ioport field:set_value(1) 可直接拉低 active-low 位，
  因此不需要 read-tap。按键释放必须显式调用 field:set_value(0)。
  注意：方向键和攻击键在同一 port 的不同 bit 上，允许组合输入。
]]

-- 加载日志模块
local Logger = require("utils.logger")
local log = Logger.new("input-controller")

-- 兼容：旧代码调用 logMsg(msg) 等价于 log:info(msg)
local function logMsg(msg) log:info(msg) end

local InputController = {}
InputController.__index = InputController

-- CPS1 SF2CE 端口映射 (通过 MAME CPS1 驱动源码 + 实测验证)
-- :IN0 - 系统按钮 (投币/开始)  8-bit, IP_ACTIVE_LOW
-- :IN1 - 方向 + 拳按钮 (P1低8位 P2高8位)  16-bit, IP_ACTIVE_LOW
-- :IN2 - 踢按钮 (部分版本通过 CPS-B 读取)  8-bit, IP_ACTIVE_LOW
local PORT_CONFIG = {
  [1] = { tag = ":IN0", fields = {
    P1_COIN_IN0      = 0x01,  -- SF2CE IN0: Coin 1 @ bit0
    P2_COIN_IN0      = 0x01,  -- SF2CE IN0: same coin slot for both players
    P1_START_IN0     = 0x10,  -- SF2CE IN0: 1 Player Start @ bit4
    P2_START_IN0     = 0x20,  -- SF2CE IN0: 2 Players Start @ bit5
  }},
  [2] = { tag = ":IN1", fields = {
    P1_JOYSTICK_RIGHT = 0x0001,
    P1_JOYSTICK_LEFT  = 0x0002,
    P1_JOYSTICK_DOWN  = 0x0004,
    P1_JOYSTICK_UP    = 0x0008,
    P1_BUTTON1        = 0x0010,
    P1_BUTTON2        = 0x0020,
    P1_BUTTON3        = 0x0040,
  }},
  [3] = { tag = ":IN1", fields = {
    P2_JOYSTICK_RIGHT = 0x0100,
    P2_JOYSTICK_LEFT  = 0x0200,
    P2_JOYSTICK_DOWN  = 0x0400,
    P2_JOYSTICK_UP    = 0x0800,
    P2_BUTTON1        = 0x1000,
    P2_BUTTON2        = 0x2000,
    P2_BUTTON3        = 0x4000,
  }},
  [4] = { tag = ":IN2", fields = {
    P1_BUTTON4 = 0x01,
    P1_BUTTON5 = 0x02,
    P1_BUTTON6 = 0x04,
    P2_BUTTON4 = 0x10,
    P2_BUTTON5 = 0x20,
    P2_BUTTON6 = 0x40,
  }},
}

-- 反向映射: inputName -> {portIndex, fieldMask, portTag} (CPS1 默认)
local INPUT_FIELD_MAP = {}
for portIdx, cfg in pairs(PORT_CONFIG) do
  for name, mask in pairs(cfg.fields) do
    INPUT_FIELD_MAP[name] = { port = portIdx, mask = mask, tag = cfg.tag }
  end
end

-- Neo Geo 动态映射: inputName -> {portTag, fieldName, mask}
local NEOGEO_FIELD_MAP = nil

local function buildNeoGeoFieldMap(romConfig)
  -- 强制重新构建，忽略缓存（调试期间）
  -- if NEOGEO_FIELD_MAP then return NEOGEO_FIELD_MAP end
  local ports = romConfig and romConfig.neogeoInputPorts
  local masks = romConfig and romConfig.neogeoFieldMasks
  if not ports or not masks then return nil end

  local map = {}
  local function add(prefix, portTag)
    for suffix, mask in pairs(masks) do
      local name = prefix .. "_" .. suffix
      local fieldName = prefix .. " " .. suffix
      -- MAME 0.288 NeoGeo 实际字段名（通过 initPorts 诊断确认）
      if suffix == "START" then
        fieldName = (prefix == "P1") and "1 Player Start" or "2 Players Start"
      elseif suffix == "COIN" then
        fieldName = (prefix == "P1") and "Coin 1" or "Coin 2"
      end
      -- NeoGeo 字段名就是 A/B/C/D，不需要 "Button 1" 转换
      log:info(string.format("[InputController] buildNeoGeoFieldMap: %s -> fieldName=%s portTag=%s", name, fieldName, portTag))
      map[name] = { portTag = portTag, fieldName = fieldName, mask = mask }
    end
  end
  add("P1", ports.p1)
  add("P2", ports.p2)
  map["P1_START"] = { portTag = ports.start, fieldName = "1 Player Start", mask = 1 }   -- bit0
  map["P2_START"] = { portTag = ports.start, fieldName = "2 Players Start", mask = 2 }  -- bit1 (P2 Start在NeoGeo $380000中为bit1)
  map["P1_COIN"] = { portTag = ports.coin, fieldName = "Coin 1", mask = masks.COIN or 1 }
  map["P2_COIN"] = { portTag = ports.coin, fieldName = "Coin 2", mask = masks.COIN2 or 2 }
  NEOGEO_FIELD_MAP = map
  return map
end

-- NeoGeo 输入注入状态（install_read_tap 方案）
local NEOGEO_TAP_STATE = {
  p1 = 0xFF,  -- 低电平有效：0xFF 表示所有按钮松开
  p2 = 0xFF,
  system = 0xFFFF,  -- SYSTEM 端口 ($380000) 16-bit，低电平有效
  tapsInstalled = false,
  tapP1 = nil,
  tapP2 = nil,
  tapSystem = nil,
}

-- 当前输入状态 (公共)
local activeInputs = {}
local comboQueue = {}
local comboTimer = 0
local isExecutingCombo = false

-- CPS1 检测缓存（必须在 installNeoGeoTaps 之前定义）
local isCPS1 = nil
local cps1_warned = false  -- 是否已经输出过相关日志

-- 检测是否是 CPS1 架构
local function detectCPS1()
  local m = manager.machine
  if not m or not m.ioport then return false end
  local port = m.ioport.ports[":IN2"]
  if not port then return false end
  for name, _ in pairs(port.fields) do
    if name:find("Kick") then return true end
  end
  return false
end

local function checkCPS1()
  if isCPS1 == nil then
    isCPS1 = detectCPS1()
  end
  return isCPS1
end

-- ============ NeoGeo Tap ============
-- 为 NeoGeo 安装 read_tap，拦截 CPU 对输入寄存器的读取
-- 这是 field:set_value 的备选/补充方案，确保在 UniBIOS 或特殊情况下也能注入输入
local function installNeoGeoTaps()
  log:info("installNeoGeoTaps called")
  if NEOGEO_TAP_STATE.tapsInstalled then
    log:info("installNeoGeoTaps: already installed")
    return
  end
  if checkCPS1() then
    log:info("installNeoGeoTaps: CPS1 detected, skipping")
    return
  end
  log:info("installNeoGeoTaps: not CPS1, proceeding")

  local cpu = manager.machine.devices[":maincpu"]
  if not cpu then
    log:warn("installNeoGeoTaps: no maincpu")
    return
  end
  log:info("installNeoGeoTaps: maincpu found")
  local space = cpu.spaces and cpu.spaces["program"]
  if not space then
    log:warn("installNeoGeoTaps: no program space")
    return
  end
  log:info("installNeoGeoTaps: program space found")

  -- 使用 2 字节范围，确保 install_read_tap 接受
  local ok1, tap1 = pcall(space.install_read_tap, space, 0x300000, 0x300001, "luafighter_neogeo_p1",
    function(offset, data, mask)
      if offset == 0x300000 then
        return (data & 0xFF00) | NEOGEO_TAP_STATE.p1
      end
      return data
    end)
  if ok1 and tap1 then
    NEOGEO_TAP_STATE.tapP1 = tap1
    log:info("NeoGeo tap: P1 installed at $300000")
  else
    log:warn(string.format("NeoGeo tap: P1 install failed, ok=%s err=%s", tostring(ok1), tostring(tap1)))
  end

  -- 拦截 P2 输入寄存器 $340000
  local ok2, tap2 = pcall(space.install_read_tap, space, 0x340000, 0x340001, "luafighter_neogeo_p2",
    function(offset, data, mask)
      if offset == 0x340000 then
        return (data & 0xFF00) | NEOGEO_TAP_STATE.p2
      end
      return data
    end)
  if ok2 and tap2 then
    NEOGEO_TAP_STATE.tapP2 = tap2
    log:info("NeoGeo tap: P2 installed at $340000")
  else
    log:warn(string.format("NeoGeo tap: P2 install failed, ok=%s err=%s", tostring(ok2), tostring(tap2)))
  end

  -- 拦截 SYSTEM 输入寄存器 $380000 (Start 键)
  -- NeoGeo $380000 位映射: bit0=P1 Start, bit1=P2 Start, bit2=SELECT, bit3+=其他
  -- 安全：只修改 Start 位（bit0 mask=1, bit1 mask=2），不修改其他位（避免触发Cheat菜单）
  local ok3, tap3 = pcall(space.install_read_tap, space, 0x380000, 0x380001, "luafighter_neogeo_system",
    function(offset, data, mask)
      if offset == 0x380000 then
        -- 只修改 Start 位，保持其他位不变
        -- NeoGeo $380000: bit0=P1 Start, bit1=P2 Start
        -- 不修改 bit2+（避免触发Cheat菜单/系统功能）
        local startMask = 0x03  -- P1 Start (bit0 mask=1) + P2 Start (bit1 mask=2)
        -- 从 NEOGEO_TAP_STATE.system 中提取 Start 位状态
        local startPressed = (~NEOGEO_TAP_STATE.system) & startMask
        -- 清零 Start 位（如果按下），保持其他位不变
        return data & ~startPressed
      end
      return data
    end)
  if ok3 and tap3 then
    NEOGEO_TAP_STATE.tapSystem = tap3
    log:info("NeoGeo tap: SYSTEM installed at $380000")
  else
    log:warn(string.format("NeoGeo tap: SYSTEM install failed, ok=%s err=%s", tostring(ok3), tostring(tap3)))
  end

  if NEOGEO_TAP_STATE.tapP1 and NEOGEO_TAP_STATE.tapP2 and NEOGEO_TAP_STATE.tapSystem then
    NEOGEO_TAP_STATE.tapsInstalled = true
    log:info("NeoGeo tap: P1/P2/SYSTEM installed successfully")
  else
    log:warn("NeoGeo tap: installation incomplete")
  end
end

-- 卸载 NeoGeo read_tap
local function removeNeoGeoTaps()
  if NEOGEO_TAP_STATE.tapP1 then
    pcall(NEOGEO_TAP_STATE.tapP1.remove, NEOGEO_TAP_STATE.tapP1)
    NEOGEO_TAP_STATE.tapP1 = nil
  end
  if NEOGEO_TAP_STATE.tapP2 then
    pcall(NEOGEO_TAP_STATE.tapP2.remove, NEOGEO_TAP_STATE.tapP2)
    NEOGEO_TAP_STATE.tapP2 = nil
  end
  if NEOGEO_TAP_STATE.tapSystem then
    pcall(NEOGEO_TAP_STATE.tapSystem.remove, NEOGEO_TAP_STATE.tapSystem)
    NEOGEO_TAP_STATE.tapSystem = nil
  end
  NEOGEO_TAP_STATE.tapsInstalled = false
  NEOGEO_TAP_STATE.p1 = 0xFF
  NEOGEO_TAP_STATE.p2 = 0xFF
  NEOGEO_TAP_STATE.system = 0xFFFF
end

-- 设置 NeoGeo 按钮状态（通过 read_tap 注入）
-- 低电平有效：按下时清零对应位，释放时置位
-- P1/P2 方向/按钮在 $300000/$340000，Start 在 $380000
local function setNeoGeoTapState(player, portName, pressed)
  local mapping = NEOGEO_FIELD_MAP and NEOGEO_FIELD_MAP[portName]
  if not mapping then
    log:warn(string.format("setNeoGeoTapState: no mapping for %s", portName))
    return
  end
  local mask = mapping.mask or 0

  -- Start 键在 SYSTEM 端口 ($380000)
  -- 使用 mapping.mask（P1_START=1, P2_START=4）
  if portName:find("_START$") then
    local systemState = NEOGEO_TAP_STATE.system
    local startMask = mapping.mask or 0
    if startMask == 0 then
      log:warn(string.format("setNeoGeoTapState: Start mask is 0 for %s", portName))
      return
    end
    if pressed then
      systemState = systemState & ~startMask  -- 按下：清零对应位
    else
      systemState = systemState | startMask   -- 释放：置位对应位
    end
    NEOGEO_TAP_STATE.system = systemState
    return
  end

  -- P1/P2 方向/按钮在 $300000/$340000
  local oldState = (player == 1) and NEOGEO_TAP_STATE.p1 or NEOGEO_TAP_STATE.p2
  local state = oldState
  if pressed then
    state = state & ~mask  -- 按下：清零对应位（低电平有效）
  else
    state = state | mask   -- 释放：置位对应位
  end

  if state ~= oldState then
    log:info(string.format("setNeoGeoTapState: P%d %s %s mask=0x%02X state=0x%02X->0x%02X",
      player, portName, pressed and "PRESSED" or "RELEASED", mask, oldState, state))
  end

  if player == 1 then
    NEOGEO_TAP_STATE.p1 = state
  else
    NEOGEO_TAP_STATE.p2 = state
  end
end

-- 获取玩家编号（从 portName 解析 P1/P2）
local function getPlayerFromPortName(portName)
  if not portName then return nil end
  if portName:find("^P1_") then return 1 end
  if portName:find("^P2_") then return 2 end
  return nil
end
local function getMapping(portName, platform)
  if not portName then return nil end
  if platform == "neogeo" then
    return NEOGEO_FIELD_MAP and NEOGEO_FIELD_MAP[portName]
  end
  return INPUT_FIELD_MAP[portName]
end

-- 平台无关：设置单个 port 的硬件状态 (value: 0 释放, 1 按下)
-- NeoGeo：同时使用 field:set_value 和 install_read_tap 双保险
-- CPS1：使用 read_tap 状态机
local function setPortValue(portName, value, platform)
  value = value or 0
  if platform == "neogeo" then
    local mapping = NEOGEO_FIELD_MAP and NEOGEO_FIELD_MAP[portName]
    if not mapping then
      log:warn(string.format("setPortValue: no mapping for %s", portName))
      return
    end
    
    -- 诊断：打印 mapping 内容
    log:info(string.format("setPortValue: %s mapping={portTag=%s fieldName=%s mask=%d}", 
      portName, tostring(mapping.portTag), tostring(mapping.fieldName), tonumber(mapping.mask) or 0))

    -- 方案 1：field:set_value（标准 ioport 层注入）
    -- 注意：对于 active-low 端口，field:set_value(0) 表示按下（低电平），set_value(1) 表示释放（高电平）
    -- 因此需要反转 value：按下时 value=1 -> 设置 0，释放时 value=0 -> 设置 1
    local digitalValue = (value == 1) and 0 or 1
    -- 同时尝试带冒号和不带冒号的端口 tag
    local port = manager.machine.ioport.ports[mapping.portTag]
    if not port then
      port = manager.machine.ioport.ports[":" .. mapping.portTag]
    end
    if port then
      local field = port.fields[mapping.fieldName]
      if field then
        local ok = pcall(field.set_value, field, digitalValue)
        if not ok then
          log:warn(string.format("setPortValue: field:set_value failed for %s", portName))
        end
      else
        log:warn(string.format("setPortValue: field not found for %s (fieldName=%s)", portName, mapping.fieldName))
      end
    else
      log:warn(string.format("setPortValue: port not found for %s (portTag=%s)", portName, mapping.portTag))
    end

    -- 方案 2：install_read_tap（直接拦截 CPU 读取，绕过 BIOS 层）
    -- P1/P2 方向/按钮在 $300000/$340000，Start 在 $380000
    installNeoGeoTaps()
    local player = getPlayerFromPortName(portName)
    if player then
      setNeoGeoTapState(player, portName, value == 1)
    end
    return
  end

  -- CPS1 / fallback
  local mapping = INPUT_FIELD_MAP[portName]
  if mapping and mapping.tag then
    if not InputController._cps_state then
      InputController._cps_state = { in0 = {}, in1 = {}, in2 = {} }
    end
    local key = ({ [":IN0"] = "in0", [":IN1"] = "in1", [":IN2"] = "in2" })[mapping.tag] or "in1"
    if value == 1 then
      InputController._cps_state[key][mapping.mask] = true
    else
      InputController._cps_state[key][mapping.mask] = nil
    end
  end
end

-- 当前输入状态 (公共)
local activeInputs = {}
local comboQueue = {}
local comboTimer = 0
local isExecutingCombo = false

function InputController.new(romConfig)
  local obj = {}
  setmetatable(obj, InputController)
  obj.config = romConfig
  obj.inputMap = {
    p1 = romConfig.p1InputMap or {},
    p2 = romConfig.p2InputMap or {},
  }
  obj.ports = {}
  obj.fields = {}
  obj.portsInitialized = false
  -- CPS1 read-tap injection state
  obj._cps_state = nil
  obj._cps_taps_installed = false
  obj._framesSinceTap = 0  -- 安装 tap 后的帧计数
  obj._lastLogFrame = 0    -- 用于限制日志频率
  -- platform detection
  obj._platform = romConfig.platform or "cps1"
  if obj._platform == "neogeo" then
    buildNeoGeoFieldMap(romConfig)
  end
  return obj
end

-- 带频率限制的日志（每 60 帧最多输出一次，避免刷屏）
local function limitedLog(msg, nowFrame, self)
  if not nowFrame then
    logMsg(msg)
    return
  end
  if not self._lastLogFrame or nowFrame - self._lastLogFrame >= 60 then
    logMsg(msg)
    self._lastLogFrame = nowFrame
  end
end

function InputController:_getField(portIndex, fieldMask)
  if not self.fields[portIndex] then
    self.fields[portIndex] = {}
  end
  local cache = self.fields[portIndex]
  if cache[fieldMask] then
    return cache[fieldMask]
  end
  local port = self.ports[portIndex]
  if not port then return nil end
  local ok, field = pcall(function() return port:field(fieldMask) end)
  if ok and field then
    cache[fieldMask] = field
    return field
  end
  return nil
end

-- 查找 DIP 端口和字段
local function findDipPortAndField()
  -- 尝试多种端口 tag（MAME 不同版本格式可能不同）
  local portTags = {":DSW", "DSW", ":DSWA", "DSWA", ":DSWB", "DSWB", ":DSWC", "DSWC"}
  -- 尝试多种字段名
  local fieldKeywords = {"cabinet", "vs mode", "game mode", "mode", "type"}
  
  local okPorts, ports = pcall(function() return manager.machine.ioport.ports end)
  if not okPorts or not ports then return nil, nil end
  
  -- 先列出所有可用端口和字段（用于诊断）
  local allPorts = {}
  for tag, p in pairs(ports) do
    table.insert(allPorts, tag)
  end
  
  for _, tag in ipairs(portTags) do
    local port = ports[tag]
    if port then
      local allFields = {}
      for fname, _ in pairs(port.fields) do
        table.insert(allFields, fname)
      end
      
      -- 尝试精确匹配 "Cabinet"
      for fname, f in pairs(port.fields) do
        if fname:lower() == "cabinet" then
          log:info(string.format("[InputController] DSW found: port=%s field=%s (from ports: %s)", 
            tag, fname, table.concat(allPorts, ",")))
          return port, f
        end
      end
      
      -- 尝试包含关键字
      for fname, f in pairs(port.fields) do
        local lowerName = fname:lower()
        for _, kw in ipairs(fieldKeywords) do
          if lowerName:find(kw) then
            log:info(string.format("[InputController] DSW found (fuzzy): port=%s field=%s keyword=%s", 
              tag, fname, kw))
            return port, f
          end
        end
      end
    end
  end
  
  log:warn(string.format("[InputController] KOF97 DSW/Cabinet not found in ports: %s", 
    table.concat(allPorts, ",")))
  return nil, nil
end

local function setKof97VsModeDip()
  -- KOF97 的 Cabinet DIP：Normal=2, VS Mode=0（mask=2）
  -- MAME ioport tag 通常带前导冒号，如 :DSW
  local port, field = findDipPortAndField()
  
  if not port then
    log:warn("[InputController] KOF97 DSW port 未找到，尝试内存写入后备方案")
    return false
  end
  
  if not field then
    log:warn("[InputController] KOF97 DSW port 找到但无 Cabinet/Mode field")
    return false
  end
  
  -- 尝试设置 VS Mode (value=0)
  local setOk, setErr = pcall(function() field:set_value(0) end)
  if setOk then
    log:info("[InputController] KOF97 Cabinet DIP 已设为 VS Mode (value=0)")
    return true
  else
    log:warn(string.format("[InputController] KOF97 Cabinet DIP 设置失败: %s", tostring(setErr)))
    return false
  end
end

function InputController:initPorts()
  local machine = manager.machine
  if not machine or not machine.ioport then
    if not cps1_warned then
      cps1_warned = true
    end
    return false
  end

  if self._platform == "neogeo" then
    -- Neo Geo 只需要确认配置中的端口存在
    local ports = self.config and self.config.neogeoInputPorts
    if ports then
      local ok = true
      for name, tag in pairs({coin=ports.coin, start=ports.start, p1=ports.p1, p2=ports.p2}) do
        -- 同时尝试带冒号和不带冒号的版本（MAME 端口 tag 通常带前导冒号）
        local portOk, port = pcall(function() return machine.ioport.ports[tag] end)
        if not portOk or not port then
          portOk, port = pcall(function() return machine.ioport.ports[":" .. tag] end)
        end
        if not portOk or not port then ok = false
          log:warn(string.format("[InputController] NeoGeo port %s (%s) NOT FOUND", name, tag))
        else
          local fieldNames = {}
          for fname, _ in pairs(port.fields) do
            table.insert(fieldNames, fname)
          end
          logMsg(string.format("[InputController] NeoGeo port %s (%s) fields: %s", name, tag, table.concat(fieldNames, ",")))
        end
      end
      -- 诊断：如果任何端口找不到，列出所有可用端口
      if not ok then
        local allPorts = {}
        local okPorts, portsTable = pcall(function() return machine.ioport.ports end)
        if okPorts and portsTable then
          for tag, _ in pairs(portsTable) do
            table.insert(allPorts, tag)
          end
        end
        log:warn(string.format("[InputController] 所有可用端口: %s", table.concat(allPorts, ", ")))
      end
      if ok then
        -- 确认 KOF97 的 Cabinet DIP 为 VS Mode，保证 1P vs 2P
        if self.config.rom and (self.config.rom):lower():find("kof97") then
          local dipOk = setKof97VsModeDip()
          if not dipOk then
            -- DIP 设置失败，不再尝试内存写入（避免触发 BIOS 保护/内存检查）
            log:warn("[InputController] DIP 设置失败，跳过内存写入（避免触发 BIOS 保护）")
          end
        end
        self.portsInitialized = true
        return true
      end
    end
  end

  for idx, cfg in pairs(PORT_CONFIG) do
    local ok, port = pcall(function() return machine.ioport.ports[cfg.tag] end)
    if ok and port then
      self.ports[idx] = port
    end
  end

  if self.ports[1] then
    self.portsInitialized = true
    return true
  end
  return false
end

-- ============ CPS1 Read-Tap Input Injection ============
-- 已验证有效的注入方案（MAME 0.288 / CPS1-SF2CE 实测通过）
--
-- 约束条件（违反会导致 tap 被 MAME 静默禁用）:
--   TAP 回调中不能有:
--   - print() 调用
--   - io.open() / io.write() / io.close() 等文件操作
--   - 任何可能抛出 Lua 错误的操作 (pcall 也救不了，错误会传播到 MAME 内存系统)
--   - 日志操作
--
-- NOTE: DSWC Free Play tap is now installed inside installCPS1Taps() below.
-- register_prestart() is NOT used because it doesn't fire reliably when
-- called from -autoboot_script (machine has already started).
-- 被拦截地址:
 --   0x800000-0x800007 : IN1 (方向/拳)  - 16-bit 端口值, active-low
 --   0x800018-0x80001B : IN0 (投币/开始) - 在 cps1_dsw_r 返回值的低字节 (value | (dsw<<8))
 --                       0x80001A 是 0x800018 的镜像，返回相同值
 --                       0x80001C/0x80001E 是 DSWB/DSWC，不要修改

function InputController:installCPS1Taps()
  if self._cps_taps_installed then return true end

  local m = manager.machine
  if not m or not m.devices then return false end

  local maincpu = m.devices[":maincpu"]
  if not maincpu then return false end

  local space = maincpu.spaces["program"]
  if not space then return false end

  self._cps_state = self._cps_state or { in0 = {}, in1 = {}, in2 = {} }
  -- Tap diagnostic counters
  self._dsw_tap_count = 0
  self._main_tap_count = 0
  self._dsw_tap_data = 0xFFFF

  -- Tap 1: IN1 @ 0x800000-0x800007 (玩家方向/拳按钮)
  -- 回调中严格禁止任何 I/O 操作！
  local ok1, tap1 = pcall(function()
    return space:install_read_tap(0x800000, 0x800007, "luafighter_in1", function(offset, data, mask)
      local modified = data
      self._main_tap_count = (self._main_tap_count or 0) + 1
      -- IN1 (low byte): player buttons/joystick
      for m, _ in pairs(self._cps_state and self._cps_state.in1 or {}) do
        modified = modified & ~m
      end
      -- IN0 (high byte): coin/start -- cps1_input_r returns (IN0 << 8) | IN1
      for m, _ in pairs(self._cps_state and self._cps_state.in0 or {}) do
        modified = modified & ~(m << 8)
      end
      return modified
    end)
  end)

  -- cps1_dsw_r() returns (IN0 << 8) | dsw(offset>>1)
  -- The full range 0x800018-0x80001F has ONE handler for all 8 bytes.
  -- Previous sub-range taps (0x800018-0x800019 for IN0, 0x80001E-0x80001F for DSWC)
  -- were silently rejected by MAME. Must install ONE tap covering the ENTIRE range.
  local ok2, tap2 = pcall(function()
    return space:install_read_tap(0x800018, 0x80001F, "luafighter_dsw", function(offset, data, mask)
      local modified = data
      self._dsw_tap_count = (self._dsw_tap_count or 0) + 1
      self._dsw_tap_data = data
      -- IN0 is in the HIGH byte for ALL offsets (0, 2, 4, 6)
      -- Must modify at ALL offsets since game reads from any of them
      for m, _ in pairs(self._cps_state and self._cps_state.in0 or {}) do
        modified = modified & ~(m << 8)
      end
      return modified
    end)
  end)

  if ok1 and ok2 and tap1 and tap2 then
   self._cps_taps_installed = true
    self._tap_in1 = tap1
    self._tap_dsw = tap2
   self._framesSinceTap = 0
   -- TEST: Read from both tap ranges to verify they intercept internal reads
   local test_main = { pcall(space.read_u16, space, 0x800000) }
   local test_dsw = { pcall(space.read_u16, space, 0x800018) }
   -- Also check: where is the space?
   local tap1_type = type(tap1)
   local tap2_type = type(tap2)
   local space_name = "(unknown)"
   local dsw_fields = {}
   if manager.machine and manager.machine.ioport then
     local in2_port = manager.machine.ioport.ports[":IN0"]
     if in2_port then
       for fname, fval in pairs(in2_port.fields) do
         table.insert(dsw_fields, fname)
       end
     end
   end
   logMsg(string.format("[InputController] CPS1 taps OK! tap1=%s tap2=%s mainTap=%d dswTap=%d in0fields=%s",
     tap1_type, tap2_type, self._main_tap_count or 0, self._dsw_tap_count or 0,
     table.concat(dsw_fields, ",")))
   return true
 end
 logMsg(string.format("[InputController] CPS1 taps FAILED! ok1=%s ok2=%s tap1=%s tap2=%s",
   tostring(ok1), tostring(ok2), type(tap1), type(tap2)))
 return false
end

-- CPS1 state helpers
function InputController:_cpsPress(portTag, mask)
  self._cps_state = self._cps_state or { in0 = {}, in1 = {}, in2 = {} }
  local key = ({ [":IN0"] = "in0", [":IN1"] = "in1", [":IN2"] = "in2" })[portTag] or "in1"
  self._cps_state[key][mask] = true
end

function InputController:_cpsRelease(portTag, mask)
  if not self._cps_state then return end
  local key = ({ [":IN0"] = "in0", [":IN1"] = "in1", [":IN2"] = "in2" })[portTag] or "in1"
  self._cps_state[key][mask] = nil
end

function InputController:_cpsClearAll()
  self._cps_state = { in0 = {}, in1 = {}, in2 = {} }
end

function InputController:_installTapsIfNeeded()
  if checkCPS1() and not self._cps_taps_installed then
    self:installCPS1Taps()
  end
end
-- ============ CPS1 End ============

-- 内部：按下/释放一个 portName（平台无关）
function InputController:_pressByName(portName, duration)
  duration = duration or 6
  if not portName then return end

  if self._platform == "neogeo" then
    setPortValue(portName, 1, "neogeo")
    activeInputs[portName] = { frames = duration }
    return
  end

  -- CPS1 / 默认路径
  local mapping = INPUT_FIELD_MAP[portName]
  if mapping and mapping.tag then
    if checkCPS1() then
      self:_installTapsIfNeeded()
      self:_cpsPress(mapping.tag, mapping.mask)
    else
      -- Non-CPS1 fallback: 标准 field:set_value
      local port = manager.machine.ioport.ports[mapping.tag]
      if port then
        local field = port:field(mapping.mask)
        if field then
          pcall(field.set_value, field, 1)
        end
      end
    end
    activeInputs[portName] = { frames = duration }
  end
end

function InputController:_releaseByName(portName)
  if not portName then return end
  if not activeInputs[portName] then
    -- 仍然尝试硬件释放，保证干净
  end

  if self._platform == "neogeo" then
    setPortValue(portName, 0, "neogeo")
    activeInputs[portName] = nil
    return
  end

  local mapping = INPUT_FIELD_MAP[portName]
  if mapping and mapping.tag then
    if checkCPS1() then
      self:_cpsRelease(mapping.tag, mapping.mask)
      -- 同时清掉标准 ioport field，防止 fallback 路径残留
      local f = self:_getField(mapping.port, mapping.mask)
      if f then pcall(f.set_value, f, 0) end
    else
      local f = self:_getField(mapping.port, mapping.mask)
      if f then pcall(f.set_value, f, 0) end
    end
  end
  activeInputs[portName] = nil
end

function InputController:releaseAll()
  for portName, _ in pairs(activeInputs) do
    self:_releaseByName(portName)
  end
  activeInputs = {}
  if checkCPS1() then
    self:_cpsClearAll()
  end
end

function InputController:press(logicalButtons, player, duration)
  duration = duration or 6
  local playerStr = player == 1 and "p1" or "p2"
  for _, btn in ipairs(logicalButtons) do
    local portName = self.inputMap[playerStr][btn]
    if portName then
      self:_pressByName(portName, duration)
    end
  end
end

function InputController:pressPorts(portNames, duration)
  duration = duration or 6
  for _, portName in ipairs(portNames) do
    self:_pressByName(portName, duration)
  end
end

function InputController:setDirection(player, direction)
  local playerStr = player == 1 and "p1" or "p2"
  local map = self.inputMap[playerStr]

  -- 将方向字符串转换为方向键集合
  local targetDirs = {}
  if direction == "left" then targetDirs = {LEFT = true}
  elseif direction == "right" then targetDirs = {RIGHT = true}
  elseif direction == "up" then targetDirs = {UP = true}
  elseif direction == "down" then targetDirs = {DOWN = true}
  elseif direction == "upleft" then targetDirs = {LEFT = true, UP = true}
  elseif direction == "upright" then targetDirs = {RIGHT = true, UP = true}
  elseif direction == "downleft" then targetDirs = {LEFT = true, DOWN = true}
  elseif direction == "downright" then targetDirs = {RIGHT = true, DOWN = true}
  end

  -- 初始化方向状态缓存
  self._directionState = self._directionState or {}
  self._directionState[player] = self._directionState[player] or {}
  local currentState = self._directionState[player]

  -- 差分更新：只修改变化的键
  for _, dir in ipairs({"UP", "DOWN", "LEFT", "RIGHT"}) do
    local portName = map[dir]
    if not portName then goto continue end

    local shouldBePressed = targetDirs[dir] == true
    local currentlyPressed = currentState[dir] == true

    if shouldBePressed ~= currentlyPressed then
      -- 状态变化，执行操作
      if shouldBePressed then
        -- 按下
        if self._platform == "neogeo" then
          self:setPersistent(portName)
        else
          self:_pressByName(portName, 999)
        end
      else
        -- 释放
        if self._platform == "neogeo" then
          self:clearPersistent(portName)
        else
          self:_releaseByName(portName)
        end
      end
      currentState[dir] = shouldBePressed
    end

    ::continue::
  end

  -- 调试：方向变化时打印
  if self._platform == "neogeo" then
    self._lastDirection = self._lastDirection or {}
    if self._lastDirection[player] ~= direction then
      logMsg(string.format("[InputController] P%d setDirection=%s (diff update)", player, tostring(direction)))
      self._lastDirection[player] = direction
    end
  end
end

function InputController:attack(player, button, duration)
  duration = duration or 6
  local playerStr = player == 1 and "p1" or "p2"
  local portName = self.inputMap[playerStr][button]
  if portName then
    self:_pressByName(portName, duration)
  end
end

function InputController:insertCoin(player)
  local playerStr = (player == 1) and "p1" or "p2"
  local portName = self.inputMap[playerStr]["COIN"]
  if portName then
    self:_pressByName(portName, 6)
  end
end

function InputController:pressStart(player)
  local playerStr = (player == 1) and "p1" or "p2"
  local portName = self.inputMap[playerStr]["START"]
  if portName then
    self:_pressByName(portName, 8)
  end
end

function InputController:executeCombo(comboName, player)
  if checkCPS1() then
    return false
  end

  local combos = self.config.combos or {}
  local combo = combos[comboName]
  if not combo then
    return false
  end

  comboQueue = {}
  for _, step in ipairs(combo) do
    table.insert(comboQueue, {
      buttons = step.buttons,
      duration = step.duration or 6,
      delay = step.delay or 0,
      player = player,
    })
  end

  isExecutingCombo = true
  comboTimer = 0
  return true
end

function InputController:updateFrame()
  if not self.portsInitialized then
    self:initPorts()
    if not self.portsInitialized then return end
  end

  if checkCPS1() then
    self:_installTapsIfNeeded()
    if self._cps_taps_installed then
      self._framesSinceTap = (self._framesSinceTap or 0) + 1
    end
    local toRelease = {}
    for portName, info in pairs(activeInputs) do
      if type(info) == "table" and info.frames then
        info.frames = info.frames - 1
        if info.frames <= 0 then
          table.insert(toRelease, portName)
        end
      elseif type(info) == "table" and info.persistent then
        -- persistent input: don't auto-release
      end
    end
    for _, portName in ipairs(toRelease) do
      self:_releaseByName(portName)
    end
    return
  end

  -- 非 CPS1（含 Neo Geo）: 标准 field:set_value 路径
  if isExecutingCombo and #comboQueue > 0 then
    comboTimer = comboTimer - 1
    if comboTimer <= 0 then
      self:releaseAll()
      local step = table.remove(comboQueue, 1)
      if step then
        local buttons = {}
        for _, btn in ipairs(step.buttons) do
          local portName = self.inputMap[step.player == 1 and "p1" or "p2"][btn]
          if portName then
            table.insert(buttons, portName)
          end
        end
        self:pressPorts(buttons, step.duration)
        comboTimer = step.duration + (step.delay or 0)
      end
      if #comboQueue == 0 then
        isExecutingCombo = false
      end
    end
  end

  local toRelease = {}
  for portName, info in pairs(activeInputs) do
    if type(info) == "table" and info.frames then
      info.frames = info.frames - 1
      if info.frames <= 0 then
        table.insert(toRelease, portName)
      end
    elseif type(info) == "table" and info.persistent then
      -- persistent input: don't auto-release
    end
  end
  for _, portName in ipairs(toRelease) do
    self:_releaseByName(portName)
  end
end

-- 估计当前游戏阶段（基于安装 tap 后的帧计数）
-- 用于上层决定是否适合投币/按键
-- SF2CE attract demo 约 25-30 秒（1500-1800 帧）
-- 保守起见 35 秒（2100 帧）后认为回到标题画面
function InputController:estimateGamePhase()
  local frames = self._framesSinceTap or 0
  if frames < 1500 then
    return "attract"
  elseif frames < 1800 then
    return "title_transition"
  end
  return "title_stable"
end

-- 持久性输入（在 updateFrame 中不会被自动释放）
function InputController:setPersistent(portName)
  if self._platform == "neogeo" then
    setPortValue(portName, 1, "neogeo")
    activeInputs[portName] = { persistent = true }
    return
  end

  local mapping = INPUT_FIELD_MAP[portName]
  if mapping then
    if checkCPS1() then
      self:_installTapsIfNeeded()
      self:_cpsPress(mapping.tag, mapping.mask)
      activeInputs[portName] = { persistent = true }
    else
      local f = self:_getField(mapping.port, mapping.mask)
      if f then pcall(f.set_value, f, 1) end
      activeInputs[portName] = { persistent = true }
    end
  end
end

function InputController:clearPersistent(portName)
  if self._platform == "neogeo" then
    setPortValue(portName, 0, "neogeo")
    activeInputs[portName] = nil
    return
  end

  local mapping = INPUT_FIELD_MAP[portName]
  if mapping then
    if checkCPS1() then
      self:_cpsRelease(mapping.tag, mapping.mask)
      activeInputs[portName] = nil
    else
      local f = self:_getField(mapping.port, mapping.mask)
      if f then pcall(f.set_value, f, 0) end
      activeInputs[portName] = nil
    end
  end
end

function InputController:clearAllPersistent()
  for portName, info in pairs(activeInputs) do
    if type(info) == "table" and info.persistent then
      self:_releaseByName(portName)
    end
  end
end

function InputController:resetCpsState()
  -- 释放旧的 CPS1 read-tap，防止 address_space 上累积
  if self._tap_in1 then
    pcall(self._tap_in1.remove, self._tap_in1)
    self._tap_in1 = nil
  end
  if self._tap_dsw then
    pcall(self._tap_dsw.remove, self._tap_dsw)
    self._tap_dsw = nil
  end
  -- 卸载 NeoGeo read-tap
  removeNeoGeoTaps()
  self._cps_taps_installed = false
  self._cps_state = nil
  self._main_tap_count = 0
  self._dsw_tap_count = 0
  self._framesSinceTap = 0
  -- 释放所有 active 输入
  for portName, _ in pairs(activeInputs) do
    self:_releaseByName(portName)
  end
  activeInputs = {}
end

function InputController:softReset()
  local machine = manager.machine
  if machine and machine.soft_reset then
    pcall(machine.soft_reset, machine)
    return
  end
  if machine and machine.hard_reset then
    pcall(machine.hard_reset, machine)
    return
  end
end

return InputController
