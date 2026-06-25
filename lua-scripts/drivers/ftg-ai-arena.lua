--[[
  FTG AI Arena - 格斗游戏自动对战 AI 框架
  =====================================================
  基于 MAME Lua API 的帧级自动化控制，支持 CPS1 (SF2CE) 与 Neo Geo (KOF97)。

  设计要点：
  - 所有内存地址从外部 romConfig 读取，地址未配置时优雅降级。
  - 仅在对战阶段 (PHASE.FIGHT) 激活；非可控状态自动松键等待。
  - 按键由 InputController 统一管理，避免直接操作底层 port/field。
  - 必杀技通过队列逐帧播放，避免在回调里 sleep/wait。
  - 严禁在本文件任何回调中使用 while true / io 阻塞操作。

  地址免责声明：
  以下 romConfig 中使用的内存地址（如血量、坐标、状态机、能量）均为参考值，
  不同 ROM 版本（日版/欧版/修改版/风云再起）的地址可能完全不同。
  请使用 MAME 调试器（按 ~ 键）自行核对后再投入使用。
]]

local FtgAiArena = {}
FtgAiArena.__index = FtgAiArena

-- 默认认为角色“可控”的状态值（站立/行走/蹲下）
-- 不同游戏需在 romConfig.controllableStates 中覆盖
local DEFAULT_CONTROLLABLE_STATES = { 0x00, 0x01, 0x02 }

-- AI 行为循环周期（帧）
local AI_CYCLE_FRAMES = 60
local STRATEGY_TTL_FRAMES = 60

-- KOF97 攻击按钮池
local KOF97_ATTACK_BUTTONS = {"BUTTON1", "BUTTON2", "BUTTON3", "BUTTON4"} -- A, B, C, D

-- 加载日志模块（与 automation.lua 共用同一 logger 配置）
local Logger = require("utils.logger")
local log = Logger.new("ftg-ai")

-- 兼容：旧代码调用 debugLog(msg) 等价于 log:debug(msg)
local function debugLog(msg) log:debug(msg) end

function FtgAiArena.new(romConfig, memReader, inputCtrl)
  local obj = {}
  setmetatable(obj, FtgAiArena)

  obj.config = romConfig or {}
  obj.mem = memReader
  obj.input = inputCtrl

  -- 游戏识别（仅用于日志/特殊分支）
  local rom = (obj.config.rom or ""):lower()
  if rom:find("sf2") then
    obj.gameId = "sf2"
  elseif rom:find("kof97") then
    obj.gameId = "kof97"
  else
    obj.gameId = "unknown"
  end

  obj.aiTimer = 0
  obj.specialQueue = { [1] = nil, [2] = nil }
  obj.lastSpecialFrame = { [1] = 0, [2] = 0 }
  obj.strategy = { [1] = nil, [2] = nil }
  obj.lastStrategyFrame = { [1] = -9999, [2] = -9999 }

  -- 随机种子只初始化一次
  math.randomseed(os.time())

  return obj
end

-- ============ 内存读写封装 ============

function FtgAiArena:_read(addr, size)
  if not addr or not self.mem then return nil end
  if size == 2 then
    return self.mem:readS16(addr)
  end
  return self.mem:readU8(addr)
end

function FtgAiArena:_write(addr, val)
  if not addr or not self.mem then return false end
  return self.mem:writeU8(addr, val)
end

function FtgAiArena:_readHealth(player)
  local addr = (player == 1) and self.config.p1HealthAddr or self.config.p2HealthAddr
  return self:_read(addr, 2) or 0
end

function FtgAiArena:_readX(player)
  local addr = (player == 1) and self.config.p1XAddr or self.config.p2XAddr
  if not addr then return 0 end
  -- KOF97 X 坐标是 Dword (32-bit)，使用 readU32
  local ok, val = pcall(self.mem.readU32, self.mem, addr)
  if ok and val and val ~= 0 then
    -- 只使用低 16 位（KOF97 坐标范围通常只使用 16 位）
    if val > 0xFFFF then val = val & 0xFFFF end
    return val
  end
  -- 最终降级：返回默认位置，确保AI能继续运行
  return (player == 1) and 80 or 240
end

function FtgAiArena:_readY(player)
  local addr = (player == 1) and self.config.p1YAddr or self.config.p2YAddr
  if not addr then return 0 end
  local ok, val = pcall(self.mem.readU32, self.mem, addr)
  if ok and val then
    if val > 0xFFFF then val = val & 0xFFFF end
    return val
  end
  return 0
end

function FtgAiArena:_readState(player)
  local addr = (player == 1) and self.config.p1StateAddr or self.config.p2StateAddr
  if not addr then return nil end
  local ok, val = pcall(self.mem.readU16, self.mem, addr)
  if ok and val then return val & 0xFF end
  return nil
end

function FtgAiArena:_readHitState(player)
  local addr = (player == 1) and self.config.p1HitStateAddr or self.config.p2HitStateAddr
  if not addr then return nil end
  local ok, val = pcall(self.mem.readU8, self.mem, addr)
  if ok and val then return val end
  return nil
end

function FtgAiArena:_readFacing(player)
  local addr = (player == 1) and self.config.p1FacingAddr or self.config.p2FacingAddr
  if not addr then return nil end
  local ok, val = pcall(self.mem.readU8, self.mem, addr)
  if ok and val then return val end
  return nil
end

-- ============ 状态锁定 ============

function FtgAiArena:lockBattleStates()
  -- 锁定血量：某些基板（如 Neo Geo KOF97）对血量区域有 watchdog/校验保护，
  -- 每帧写入会触发 WORK RAM ERROR。默认关闭，仅在 romConfig.lockHealth=true 时开启。
  if self.config.lockHealth then
    local maxHp = self.config.maxHealth or 144
    if self.config.p1HealthAddr then self:_write(self.config.p1HealthAddr, maxHp) end
    if self.config.p2HealthAddr then self:_write(self.config.p2HealthAddr, maxHp) end
  end

  -- 锁定时间：某些游戏（如 KOF97）的时间地址受保护，
  -- 每帧写入会导致 WORK RAM ERROR。默认关闭，仅在 romConfig.lockTime=true 时开启。
  if self.config.lockTime and self.config.timeAddr then
    local lockTime = self.config.lockTimeValue
    if not lockTime then
      lockTime = (self.gameId == "kof97") and 0x3C or 0x63
    end
    self:_write(self.config.timeAddr, lockTime)
  end

  -- 锁定能量（KOF 系列）：同样需要显式开启，避免未经验证的地址触发保护
  if self.config.lockPower and self.config.lockPowerValue then
    if self.config.p1PowerAddr then self:_write(self.config.p1PowerAddr, self.config.lockPowerValue) end
    if self.config.p2PowerAddr then self:_write(self.config.p2PowerAddr, self.config.lockPowerValue) end
  end
end

-- ============ 可控性判断 ============

function FtgAiArena:isControllable(player)
  -- 使用多维度判断角色是否可控
  -- 维度1: 状态值（基本状态）
  -- 维度2: 受击状态（硬直/倒地/被投）
  -- 维度3: 动画标志（超必杀动画中）
  -- 维度4: 格挡硬直计时器
  
  local state = self:_readState(player)
  local hitState = self:_readHitState(player)
  
  -- 如果未配置状态地址，默认认为可控（由上层 phase 保护）
  if state == nil then return true end
  
  -- 维度2: 受击状态检查
  -- 如果 hitState 非零，角色处于受击/硬直/倒地状态，不可控
  if hitState and hitState ~= 0 then
    return false
  end
  
  -- 维度1: 基本状态检查
  -- 可控状态列表：站立、蹲下、行走、后退、跳跃
  local okStates = self.config.controllableStates or DEFAULT_CONTROLLABLE_STATES
  for _, s in ipairs(okStates) do
    if state == s then return true end
  end
  
  -- 扩展可控状态（跳跃中仍可输入）
  -- 根据 KOF97 常见状态值：4=跳跃, 5=跳跃中攻击
  if state == 4 or state == 5 then
    return true
  end
  
  -- 防御状态（可以取消防御进行反击）
  if state == 6 or state == 7 then
    return true
  end
  
  -- 其他状态：默认不可控（如投技、超必杀动画、倒地起身等）
  return false
end

-- ============ 距离与朝向 ============

function FtgAiArena:getDistance()
  return math.abs(self:_readX(1) - self:_readX(2))
end

-- true = 面朝右，false = 面朝左
-- 使用朝向地址直接读取（0=朝右, 1=朝左），比通过X坐标计算更可靠
function FtgAiArena:isFacingRight(player)
  local facing = self:_readFacing(player)
  if facing ~= nil then
    return facing == 0  -- 0=朝右, 1=朝左
  end
  -- 降级：通过X坐标计算
  local myX = self:_readX(player)
  local otherX = self:_readX(player == 1 and 2 or 1)
  return myX < otherX
end

-- ============ 基础输入 ============

function FtgAiArena:moveToward(player)
  local faceRight = self:isFacingRight(player)
  self.input:setDirection(player, faceRight and "right" or "left")
end

function FtgAiArena:moveAway(player)
  local faceRight = self:isFacingRight(player)
  self.input:setDirection(player, faceRight and "left" or "right")
end

function FtgAiArena:attack(player, button)
  if not button and self.gameId == "kof97" then
    -- KOF97: 随机使用 A/B/C/D 增加战斗变化
    button = KOF97_ATTACK_BUTTONS[math.random(1, 4)]
  end
  button = button or "BUTTON1"
  self.input:attack(player, button, 6)
end

function FtgAiArena:defend(player)
  -- 简化防御：拉后（远离对手）
  self:moveAway(player)
end

function FtgAiArena:releaseAll()
  self.input:releaseAll()
end

-- ============ 必杀技序列播放器 ============

function FtgAiArena:queueSpecial(player, comboName)
  local combos = self.config.combos or {}
  local seq = combos[comboName]
  if not seq or #seq == 0 then return false end

  -- 复制序列，避免修改原配置
  local copy = {}
  for _, step in ipairs(seq) do
    table.insert(copy, {
      buttons = step.buttons,
      duration = step.duration or 6,
      delay = step.delay or 0,
    })
  end

  self.specialQueue[player] = {
    steps = copy,
    idx = 1,
    wait = 0,
  }
  return true
end

function FtgAiArena:_updateSpecial(player)
  local q = self.specialQueue[player]
  if not q then return end

  if q.wait > 0 then
    q.wait = q.wait - 1
    return
  end

  local step = q.steps[q.idx]
  if not step then
    self.specialQueue[player] = nil
    return
  end

  self.input:press(step.buttons, player, step.duration)
  q.wait = step.duration + step.delay
  q.idx = q.idx + 1
end

function FtgAiArena:isExecutingSpecial(player)
  return self.specialQueue[player] ~= nil
end

-- ============ AI 状态机 ============

function FtgAiArena:setStrategy(player, strategy, frameCount)
  if player ~= 1 and player ~= 2 then return false end
  self.strategy[player] = strategy
  self.lastStrategyFrame[player] = frameCount or self.aiTimer
  return true
end

function FtgAiArena:_getActiveStrategy(player, frameCount)
  local strategy = self.strategy[player]
  if not strategy then return nil end
  local lastFrame = self.lastStrategyFrame[player] or -9999
  local now = frameCount or self.aiTimer
  if now - lastFrame > STRATEGY_TTL_FRAMES then
    return nil
  end
  return strategy
end

function FtgAiArena:_sampleMove(strategy)
  local mt = strategy and strategy.moveTendency
  if not mt then return nil end

  local total = (mt.forward or 0) + (mt.backward or 0) + (mt.jump or 0) + (mt.crouch or 0) + (mt.neutral or 0)
  if total <= 0 then return "neutral" end

  local r = math.random() * total
  local cursor = mt.forward or 0
  if r < cursor then return "forward" end
  cursor = cursor + (mt.backward or 0)
  if r < cursor then return "backward" end
  cursor = cursor + (mt.jump or 0)
  if r < cursor then return "jump" end
  cursor = cursor + (mt.crouch or 0)
  if r < cursor then return "crouch" end
  return "neutral"
end

function FtgAiArena:_applyStrategyMove(player, strategy)
  local intent = self:_sampleMove(strategy)
  if intent == "forward" then
    self:moveToward(player)
  elseif intent == "backward" then
    self:moveAway(player)
  elseif intent == "jump" then
    self.input:press({"UP"}, player, 4)
  elseif intent == "crouch" then
    self.input:press({"DOWN"}, player, 6)
  else
    self.input:setDirection(player, "neutral")
  end
end

function FtgAiArena:_runStrategyPlayer(player, strategy, frameCount)
  if self:isExecutingSpecial(player) then return true end

  local rawDist = self:getDistance()
  local attackDist = self.config.attackDistance or 50
  local action = strategy.action or "neutral"
  local specialMove = strategy.specialMove

  -- NeoGeo坐标归一化
  local dist = rawDist
  if self.gameId == "kof97" then
    dist = math.floor(rawDist / 64)
    attackDist = 120
  end

  if specialMove and dist <= attackDist * 2 and (frameCount - (self.lastSpecialFrame[player] or 0)) >= 90 then
    if self:queueSpecial(player, specialMove) then
      self.lastSpecialFrame[player] = frameCount
      return true
    end
  end

  if action == "aggressive" then
    if dist > attackDist then
      self:moveToward(player)
    else
      self:attack(player, "BUTTON1")
    end
    return true
  end

  if action == "defensive" then
    if dist < attackDist * 1.5 then
      self:defend(player)
    else
      self:_applyStrategyMove(player, strategy)
    end
    return true
  end

  if dist <= attackDist and frameCount % 24 == (player - 1) * 12 then
    self:attack(player, "BUTTON1")
    return true
  end

  self:_applyStrategyMove(player, strategy)
  return true
end

function FtgAiArena:_chooseSpecialForPlayer(player)
  local combos = self.config.combos
  if not combos then return nil end

  -- 简单策略：P1 优先用第一个必杀，P2 优先用第二个；都只有一个则用同一个
  local names = {}
  for name, _ in pairs(combos) do
    table.insert(names, name)
  end
  if #names == 0 then return nil end

  table.sort(names) -- 保证确定性
  local idx = ((player - 1) % #names) + 1
  return names[idx]
end

-- ============ 三层 AI 控制系统 ============
-- Layer 1: 执行层 (每帧) - 方向微调、攻击按钮、防御
-- Layer 2: 战术层 (每 6 帧) - 距离判断、防御/反击、攻击时机
-- Layer 3: 策略层 (每 60 帧) - 整体策略选择、连招选择

local TACTICAL_INTERVAL = 6    -- 战术层决策间隔
local STRATEGY_INTERVAL = 60   -- 策略层决策间隔

function FtgAiArena:_runPlayerAi(player, frameCount)
  -- 如果该玩家正在放必杀，不覆盖指令
  if self:isExecutingSpecial(player) then return end

  local strategy = self:_getActiveStrategy(player, frameCount)
  if strategy then
    self:_runStrategyPlayer(player, strategy, frameCount)
    return
  end

  -- 读取基础状态
  local myHp = self:_readHealth(player)
  local enemyHp = self:_readHealth(player == 1 and 2 or 1)
  local hpDiff = myHp - enemyHp
  local rawDist = self:getDistance()
  local attackDist = self.config.attackDistance or 50

  -- NeoGeo坐标处理
  local dist = rawDist
  local xReliable = true
  if self.gameId == "kof97" then
    dist = math.floor(rawDist / 64)
    attackDist = 120
    local x1 = self:_readX(1)
    local x2 = self:_readX(2)
    if x1 == 80 and x2 == 240 then
      xReliable = false
      dist = attackDist
    end
  end

  -- ===== Layer 3: 策略层 (每 60 帧) =====
  local isDesperate = false
  local isAggressive = false
  local preferredRange = "close"  -- close / mid / far

  if self.aiTimer % STRATEGY_INTERVAL == 0 then
    isDesperate = hpDiff < -20
    isAggressive = hpDiff > -10
    
    -- 策略选择
    if isDesperate then
      preferredRange = "close"  -- 拼命：全力靠近
    elseif isAggressive then
      preferredRange = "close"  -- 优势：压制
    else
      preferredRange = "mid"    -- 均势：保持中距离
    end
    
    -- 缓存策略状态
    self._strategyState = self._strategyState or {}
    self._strategyState[player] = {
      isDesperate = isDesperate,
      isAggressive = isAggressive,
      preferredRange = preferredRange,
      frameSet = frameCount
    }
  else
    -- 使用缓存的策略状态
    local ss = self._strategyState and self._strategyState[player]
    if ss and (frameCount - ss.frameSet) < STRATEGY_INTERVAL * 2 then
      isDesperate = ss.isDesperate
      isAggressive = ss.isAggressive
      preferredRange = ss.preferredRange
    else
      isDesperate = hpDiff < -20
      isAggressive = hpDiff > -10
    end
  end

  -- ===== Layer 2: 战术层 (每 6 帧) =====
  local tacticalAction = nil  -- nil / "approach" / "retreat" / "attack" / "defend" / "combo"
  
  if self.aiTimer % TACTICAL_INTERVAL == 0 then
    if not xReliable then
      -- 坐标不可靠：纯近战
      tacticalAction = "attack"
    elseif dist > attackDist * 2 then
      -- 太远：靠近
      tacticalAction = "approach"
    elseif dist > attackDist then
      -- 中等距离
      if preferredRange == "close" then
        tacticalAction = "approach"
      else
        tacticalAction = "attack"  -- 中距离也可攻击
      end
    else
      -- 近距离
      if isDesperate then
        tacticalAction = "combo"   -- 拼命：尝试连招
      else
        tacticalAction = "attack"  -- 正常：攻击
      end
    end
    
    -- 缓存战术状态
    self._tacticalState = self._tacticalState or {}
    self._tacticalState[player] = {
      action = tacticalAction,
      frameSet = frameCount
    }
  else
    -- 使用缓存的战术状态
    local ts = self._tacticalState and self._tacticalState[player]
    if ts and (frameCount - ts.frameSet) < TACTICAL_INTERVAL * 2 then
      tacticalAction = ts.action
    end
  end

  -- ===== Layer 1: 执行层 (每帧) =====
  -- 根据战术状态执行具体动作
  if tacticalAction == "approach" then
    self:moveToward(player)
  elseif tacticalAction == "retreat" then
    self:moveAway(player)
  elseif tacticalAction == "defend" then
    self:defend(player)
  elseif tacticalAction == "attack" then
    self:moveToward(player)
    self:attack(player, nil)
  elseif tacticalAction == "combo" then
    self:moveToward(player)
    self:_trySpecialMove(player, dist, frameCount, isDesperate, xReliable)
  else
    -- 默认：靠近
    self:moveToward(player)
  end

  -- 详细日志：每60帧输出一次
  if self.aiTimer % 60 == 0 then
    local x1 = self:_readX(1)
    local x2 = self:_readX(2)
    local s1 = self:_readState(1) or -1
    local s2 = self:_readState(2) or -1
    log:info(string.format("[FTG AI] P%d F%d | HP:%d/%d | X:%d/%d | dist=%d | tactic=%s | strat=%s",
      player, frameCount, myHp, enemyHp, x1, x2, dist,
      tostring(tacticalAction), tostring(preferredRange)))
  end
end

-- 尝试释放特殊技/连招
-- xReliable: 坐标是否可靠（false时优先使用近身连招）
function FtgAiArena:_trySpecialMove(player, dist, frameCount, isDesperate, xReliable)
  xReliable = xReliable ~= false
  local lastSpecial = self.lastSpecialFrame[player] or 0
  local cooldown = isDesperate and 30 or 60
  if (frameCount - lastSpecial) < cooldown then
    self:attack(player, nil)
    return
  end

  local combos = self.config.combos or {}
  local comboNames = {}
  for name, _ in pairs(combos) do
    table.insert(comboNames, name)
  end
  if #comboNames == 0 then
    self:attack(player, nil)
    return
  end

  -- 根据距离和策略选择连招
  -- 当坐标不可靠时，优先使用近身连招（light_combo, heavy_combo, rapid_punch, crouch_kick）
  local availableCombos = {}
  for _, name in ipairs(comboNames) do
    if name == "super_special" then
      -- 超必杀只在拼命模式且冷却足够时尝试
      if isDesperate and (frameCount - lastSpecial) >= 90 then
        table.insert(availableCombos, name)
      end
    elseif name == "jump_attack" then
      -- 跳跃攻击在中距离时
      if dist > 50 and dist < 200 then
        table.insert(availableCombos, name)
      end
    elseif name == "power_wave" or name == "rising_tackle" or name == "anti_air" then
      -- 远程技能只在坐标可靠且距离较远时
      if xReliable and dist > 150 then
        table.insert(availableCombos, name)
      end
    elseif name == "dash_punch" or name == "dash_attack" then
      -- 突进技能在中距离时
      if dist > 60 and dist < 180 then
        table.insert(availableCombos, name)
      end
    elseif name == "throw_attempt" then
      -- 投技在非常近身时
      if dist < 40 then
        table.insert(availableCombos, name)
      end
    else
      -- 其他连招（light_combo, heavy_combo, crouch_kick, rapid_punch）在近身时使用
      if dist < 150 then
        table.insert(availableCombos, name)
      end
    end
  end

  -- 当坐标不可靠时，过滤掉远程连招，只保留近身连招
  if not xReliable then
    local meleeCombos = {}
    for _, name in ipairs(availableCombos) do
      if name == "light_combo" or name == "heavy_combo" or name == "rapid_punch" 
          or name == "crouch_kick" or name == "throw_attempt" then
        table.insert(meleeCombos, name)
      end
    end
    if #meleeCombos > 0 then
      availableCombos = meleeCombos
    end
  end

  if #availableCombos == 0 then
    self:attack(player, nil)
    if self.aiTimer % 30 == 0 then
      log:info(string.format("[FTG AI] P%d no-combo-available: fallback to basic attack (dist=%d xReliable=%s)", 
        player, dist, tostring(xReliable)))
    end
    return
  end

  -- 随机选择可用连招，拼命模式优先选择高伤害连招
  local comboName
  if isDesperate and math.random(1, 10) > 3 then
    -- 70%概率选择高伤害连招
    for _, name in ipairs(availableCombos) do
      if name == "dash_attack" or name == "super_special" or name == "heavy_combo" then
        comboName = name
        break
      end
    end
  end
  if not comboName then
    comboName = availableCombos[math.random(1, #availableCombos)]
  end

  if self:queueSpecial(player, comboName) then
    self.lastSpecialFrame[player] = frameCount
    log:info(string.format("[FTG AI] P%d 释放连招: %s (dist=%d xReliable=%s available=%d)", 
      player, comboName, dist, tostring(xReliable), #availableCombos))
  end
end

-- 主帧更新：由 automation.lua 的 register_periodic 回调每帧调用
function FtgAiArena:updateFrame(frameCount)
  self.aiTimer = self.aiTimer + 1

  -- 1. 持续锁定血量/时间/能量
  self:lockBattleStates()

  -- 2. 推进必杀技序列
  self:_updateSpecial(1)
  self:_updateSpecial(2)

  -- 3. 检查双方可控性。若任一方受击/倒地，清空常规输入，等待恢复。
  local p1Ctrl = self:isControllable(1)
  local p2Ctrl = self:isControllable(2)
  if not p1Ctrl or not p2Ctrl then
    self.input:releaseAll()
    if self.aiTimer % 60 == 0 then
      debugLog(string.format("[FTG AI] 不可控状态，松键等待 P1Ctrl=%s P2Ctrl=%s", tostring(p1Ctrl), tostring(p2Ctrl)))
    end
    return
  end

  -- 4. 运行双方 AI
  self:_runPlayerAi(1, frameCount)
  self:_runPlayerAi(2, frameCount)

  -- 5. 周期性详细战斗日志（每30帧）
  if self.aiTimer % 30 == 0 then
    local dist = self:getDistance()
    local x1, x2 = self:_readX(1), self:_readX(2)
    local y1, y2 = self:_readY(1), self:_readY(2)
    local hp1, hp2 = self:_readHealth(1), self:_readHealth(2)
    local s1, s2 = self:_readState(1) or -1, self:_readState(2) or -1
    local h1, h2 = self:_readHitState(1) or -1, self:_readHitState(2) or -1
    local f1, f2 = self:_readFacing(1) or -1, self:_readFacing(2) or -1
    local xReliable = not (self.gameId == "kof97" and x1 == 80 and x2 == 240)
    log:info(string.format("[FTG AI] ===== F%d Summary =====", frameCount or 0))
    log:info(string.format("[FTG AI] HP: P1=%d P2=%d | X: P1=%d P2=%d | Y: P1=%d P2=%d | dist=%d | xReliable=%s",
      hp1, hp2, x1, x2, y1, y2, dist, tostring(xReliable)))
    log:info(string.format("[FTG AI] State: P1=%d P2=%d | Hit: P1=%d P2=%d | Face: P1=%d P2=%d",
      s1, s2, h1, h2, f1, f2))
    log:info(string.format("[FTG AI] Special Q: P1=%s P2=%s | Strategy: P1=%s P2=%s",
      tostring(self.specialQueue[1] ~= nil), tostring(self.specialQueue[2] ~= nil),
      tostring(self.strategy[1] or "nil"), tostring(self.strategy[2] or "nil")))
    log:info(string.format("[FTG AI] Controllable: P1=%s P2=%s | Phase=%d",
      tostring(p1Ctrl), tostring(p2Ctrl), self.aiTimer % AI_CYCLE_FRAMES))
  end
end

-- ============ 选人阶段辅助 ============

function FtgAiArena:randomSelect(frameCount)
  -- 增强随机选人：更频繁的方向变化 + 随机确认时机
  local cycle = frameCount % 12  -- 缩短周期，加快选人速度

  if cycle == 0 then
    self.input:releaseAll()
  elseif cycle >= 1 and cycle < 10 then
    -- 随机方向移动光标，每帧都随机
    local dirs = { "LEFT", "RIGHT", "UP", "DOWN" }
    self.input:press({ dirs[math.random(1, 4)] }, 1, 2)
    self.input:press({ dirs[math.random(1, 4)] }, 2, 2)
    -- 20%概率提前确认选人（模拟人类犹豫后决定）
    if math.random(1, 100) > 80 then
      self.input:press({ "BUTTON1" }, 1, 3)
      self.input:press({ "BUTTON1" }, 2, 3)
    end
  elseif cycle >= 10 then
    -- 强制确认选人
    self.input:press({ "BUTTON1" }, 1, 4)
    self.input:press({ "BUTTON1" }, 2, 4)
  end
end

return FtgAiArena
