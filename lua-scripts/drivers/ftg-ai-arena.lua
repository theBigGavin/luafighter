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
  -- KOF97 X坐标可能是1字节值，尝试readU8
  local ok, val = pcall(self.mem.readU8, self.mem, addr)
  if ok and val then return val end
  -- 如果readU8失败，尝试readU16并取低8位
  ok, val = pcall(self.mem.readU16, self.mem, addr)
  if ok and val then return val & 0xFF end
  return 0
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
  local addr = (player == 1) and self.config.p1StateAddr or self.config.p2StateAddr
  if not addr then
    -- 未配置状态地址时默认认为可控，由上层 phase 保护
    return true
  end

  local state = self:_read(addr, 1) or 0xFF
  local okStates = self.config.controllableStates or DEFAULT_CONTROLLABLE_STATES
  for _, s in ipairs(okStates) do
    if state == s then return true end
  end
  return false
end

-- ============ 距离与朝向 ============

function FtgAiArena:getDistance()
  return math.abs(self:_readX(1) - self:_readX(2))
end

-- true = 面朝右，false = 面朝左
function FtgAiArena:isFacingRight(player)
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

  local dist = self:getDistance()
  local attackDist = self.config.attackDistance or 50
  local action = strategy.action or "neutral"
  local specialMove = strategy.specialMove

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

function FtgAiArena:_runPlayerAi(player, frameCount)
  -- 如果该玩家正在放必杀，不覆盖指令
  if self:isExecutingSpecial(player) then return end

  local strategy = self:_getActiveStrategy(player, frameCount)
  if strategy then
    self:_runStrategyPlayer(player, strategy, frameCount)
    return
  end

  local myHp = self:_readHealth(player)
  local enemyHp = self:_readHealth(player == 1 and 2 or 1)
  local hpDiff = myHp - enemyHp
  local dist = self:getDistance()
  local attackDist = self.config.attackDistance or 50
  local phase = self.aiTimer % AI_CYCLE_FRAMES

  -- 根据血量差调整策略
  local isDesperate = hpDiff < -20
  local isAggressive = hpDiff > -10

  -- 距离远：全力靠近（不攻击，只移动）
  if dist > attackDist then
    self:moveToward(player)
    return
  end

  -- 距离中等（8000-12000）：前进+攻击（边走边打）
  if dist > 8000 then
    self:moveToward(player)
    if phase % 5 == 0 then
      self:attack(player, nil)
    end
    return
  end

  -- 距离近（<8000）：攻击主导，所有阶段都攻击（不防御）
  -- 减少防御时间，给双方更多反击机会
  if phase % 10 == 0 then
    -- 每10帧尝试一次连招
    self:_trySpecialMove(player, dist, frameCount, isDesperate)
  else
    -- 持续攻击+前进（边走边打）
    self:moveToward(player)
    self:attack(player, nil)
  end
end

-- 尝试释放特殊技/连招
function FtgAiArena:_trySpecialMove(player, dist, frameCount, isDesperate)
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
  local availableCombos = {}
  for _, name in ipairs(comboNames) do
    -- 超必杀只在拼命模式且冷却足够时尝试
    if name == "super_special" then
      if isDesperate and (frameCount - lastSpecial) >= 90 then
        table.insert(availableCombos, name)
      end
    -- 跳跃攻击在距离适中时
    elseif name == "jump_attack" then
      if dist > 5000 and dist < 15000 then
        table.insert(availableCombos, name)
      end
    -- 气功波/升龙在距离较远时
    elseif name == "power_wave" or name == "rising_tackle" then
      if dist > 8000 then
        table.insert(availableCombos, name)
      end
    -- 其他连招（light_combo, dash_attack, crouch_kick）在近身时使用
    else
      if dist < 12000 then
        table.insert(availableCombos, name)
      end
    end
  end

  if #availableCombos == 0 then
    self:attack(player, nil)
    return
  end

  -- 随机选择可用连招，拼命模式优先选择高伤害连招
  local comboName
  if isDesperate and math.random(1, 10) > 3 then
    -- 70%概率选择dash_attack或super_special（高伤害）
    for _, name in ipairs(availableCombos) do
      if name == "dash_attack" or name == "super_special" then
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
    debugLog(string.format("[FTG AI] P%d 释放连招: %s", player, comboName))
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

  -- 5. 周期性调试输出
  if self.aiTimer % 60 == 0 then
    local dist = self:getDistance()
    local x1, x2 = self:_readX(1), self:_readX(2)
    debugLog(string.format("[FTG AI] F%d dist=%d P1X=%d P2X=%d phase=%d", frameCount or 0, dist, x1, x2, self.aiTimer % AI_CYCLE_FRAMES))
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
