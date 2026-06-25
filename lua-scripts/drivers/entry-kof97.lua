--[[
  KOF97 进场状态机（P1 Start -> P2 Start 加入版）
  =================================================
  目标：把 KOF97 推进到 1P vs 2P 对战状态。

  KOF97 + Universe BIOS 进场要点：
  - title/press start 画面需要同时给 P1/P2 投入硬币并按 Start。
  - 按 P1 Start 进入 1P 模式；在角色选择前按 P2 Start 才会切换为 1P vs 2P。
  - 最稳定的自动化做法：投币后同时按下 P1 Start + P2 Start，再持续按 A 确认选人。

  进场序列：
    boot wait -> title -> coin -> P1+P2 Start -> wait -> A -> loop
]]

local EntryKof97 = {}
EntryKof97.__index = EntryKof97

local STATE = {
  IDLE = "idle",
  BOOT = "boot",
  TITLE = "title",
  COIN_PRESS = "coin_press",
  COIN_WAIT = "coin_wait",
  BOTH_START_PRESS = "both_start_press",
  BOTH_START_WAIT = "both_start_wait",
  SELECT_RANDOM = "select_random",  -- 新增：随机选人阶段
  A_PRESS = "a_press",
  A_WAIT = "a_wait",
  FIGHT = "fight",
  FAILED = "failed",
}

local DEBUG_LOG = "/tmp/luafighter-debug.log"
-- 加载日志模块
local Logger = require("utils.logger")
local log = Logger.new("entry-kof97")

-- 兼容：旧代码调用 debugLog(msg) 等价于 log:info(msg)
local function debugLog(msg) log:info("[LuaFighter] " .. msg) end

function EntryKof97.new(romConfig, memReader, inputCtrl, opts)
  local obj = {}
  setmetatable(obj, EntryKof97)

  obj.config = romConfig or {}
  obj.mem = memReader
  obj.input = inputCtrl
  obj.opts = opts or {}

  obj.state = STATE.IDLE
  obj.stateFrame = 0
  obj.cycle = 0
  obj.maxCycles = 20
  obj.fallbackToCpu = false
  obj.fightConfirmFrames = 0

  math.randomseed(os.time())

  return obj
end

function EntryKof97:getState() return self.state end
function EntryKof97:isFinished() return self.state == STATE.FIGHT end
function EntryKof97:isFight() return self.state == STATE.FIGHT end

function EntryKof97:reset()
  self.state = STATE.IDLE
  self.stateFrame = 0
  self.cycle = 0
  self.fallbackToCpu = false
  self.fightConfirmFrames = 0
  debugLog("KOF97 进场状态机已重置")
end

function EntryKof97:_readBattleSignals()
  local timeAddr = self.config.timeAddr
  local p1HpAddr = self.config.p1HealthAddr
  local p2HpAddr = self.config.p2HealthAddr
  local stateAddr = self.config.stateAddress
  local battleModeAddr1 = self.config.battleModeAddr1
  local time = timeAddr and self.mem:readU8(timeAddr) or nil
  local p1Hp = p1HpAddr and self.mem:readU16(p1HpAddr) or nil
  local p2Hp = p2HpAddr and self.mem:readU16(p2HpAddr) or nil
  local stateVal = stateAddr and self.mem:readU8(stateAddr) or nil
  local bm1 = battleModeAddr1 and self.mem:readU8(battleModeAddr1) or nil
  debugLog(string.format("[EntryKof97] battle signals: time=%s p1Hp=%s p2Hp=%s state=%s bm1=%s",
    tostring(time), tostring(p1Hp), tostring(p2Hp), tostring(stateVal), tostring(bm1)))
  return time, p1Hp, p2Hp
end

function EntryKof97:_ensureVsMode()
  -- 禁用内存写入强制 VS Mode — 可能触发 BIOS 保护/内存检查
  -- 改为只读取检测，不写入
  local bm1Addr = self.config.battleModeAddr1
  if not bm1Addr then return false end
  
  local ok1, bm1 = pcall(self.mem.readU8, self.mem, bm1Addr)
  if ok1 then
    debugLog(string.format("[EntryKof97] battleModeAddr1=%s current=%s", bm1Addr, tostring(bm1)))
  end
  
  -- 只检测，不修改（避免触发 BIOS 保护）
  if ok1 and bm1 == 0x09 then
    debugLog("[EntryKof97] 检测到 VS Mode (0x09)")
    return true
  end
  
  -- KOF97 实测：战斗触发时 bm1=26 (0x1A)，也视为 VS Mode
  if ok1 and bm1 == 26 then
    debugLog("[EntryKof97] 检测到战斗模式 (0x1A/26)，等同于 VS Mode")
    return true
  end
  
  debugLog("[EntryKof97] 未检测到 VS Mode，跳过内存写入（避免触发保护）")
  return false
end

function EntryKof97:_detectFight()
  local time, p1Hp, p2Hp = self:_readBattleSignals()
  local bm1Addr = self.config.battleModeAddr1
  local bm1 = bm1Addr and self.mem:readU8(bm1Addr) or nil
  
  -- 条件1：传统检测（时间+双方血量）
  local hasBattleSignals = time and time > 0 and time <= 96 and p1Hp and p2Hp and p1Hp > 0 and p2Hp > 0
  
  -- 条件2：bm1=26 (0x1A) 战斗模式 + p1Hp>0（KOF97实测：战斗触发后bm1=26且p1Hp开始减少）
  local hasBattleMode = bm1 and bm1 == 26 and p1Hp and p1Hp > 0
  
  -- 条件3：p1Hp 从0变为>0（角色首次加载，战斗即将开始）
  local hpAppeared = p1Hp and p1Hp > 0 and (not self._lastP1Hp or self._lastP1Hp == 0)
  self._lastP1Hp = p1Hp or 0
  
  if not (hasBattleSignals or hasBattleMode or hpAppeared) then
    self.fightConfirmFrames = 0
    return false
  end
  
  -- 降低确认帧数到30（p1Hp下降很快，需要更快响应）
  self.fightConfirmFrames = self.fightConfirmFrames + 1
  if self.fightConfirmFrames >= 30 then
    debugLog(string.format("[EntryKof97] 战斗检测通过：传统=%s 战斗模式=%s hp首次=%s 确认帧=%d",
      tostring(hasBattleSignals), tostring(hasBattleMode), tostring(hpAppeared), self.fightConfirmFrames))
    return true
  end
  
  return false
end

function EntryKof97:_isVsMode()
  local bm1Addr = self.config.battleModeAddr1
  if not bm1Addr then return true end
  
  local ok, bm1 = pcall(self.mem.readU8, self.mem, bm1Addr)
  if not ok then return true end
  
  -- 0x09 = VS Mode, 0x10 = Team Mode, 0x1A(26) = 战斗模式（KOF97实测）
  if bm1 == 0x10 then
    debugLog("[EntryKof97] 检测到 Team Mode (0x10)，不是 VS Mode")
    return false
  end
  
  -- 接受 VS Mode (0x09) 或战斗模式 (0x1A/26)
  return true
end

function EntryKof97:_setState(newState, detail)
  if newState ~= self.state then
    local msg = string.format("[EntryKof97-STATE] %s -> %s (frame=%d, detail=%s)",
      tostring(self.state), tostring(newState), self.stateFrame, tostring(detail))
    print(msg)
    debugLog(msg)
    self.state = newState
    self.stateFrame = 0
  end
end

function EntryKof97:_press(buttons, player, duration)
  self.input:press(buttons, player, duration or 6)
end

function EntryKof97:_releaseAll()
  self.input:releaseAll()
end

function EntryKof97:update(frameCount)
  if self:isFinished() then return end

  self.stateFrame = self.stateFrame + 1
  
  -- 调试：强制打印当前状态（每60帧）
  if self.stateFrame % 60 == 0 then
    print(string.format("[EntryKof97-DEBUG] state=%s stateFrame=%d", tostring(self.state), self.stateFrame))
  end

  -- 全局优先：检测到对战标志立即成功
  if self:_detectFight() then
    self:_releaseAll()
    self:_setState(STATE.FIGHT, "battle signals detected")
    return
  end

  -- 使用状态字节加速状态切换
  local stateAddr = self.config.stateAddress
  local sv = self.config.stateValues or {}
  local stateVal = stateAddr and self.mem:readU8(stateAddr) or 0

  if self.state == STATE.IDLE then
    self:_setState(STATE.BOOT, "init")
    return
  end

  if self.state == STATE.BOOT then
    -- 强制等待 MAME 完成 BIOS 初始化（NeoGeo logo → SNK logo → 标题）
    -- stateVal 在 BIOS 阶段为 0，不可靠，使用固定等待时间
    if self.stateFrame >= 600 then  -- 600帧 (~10秒)，让 BIOS 完成初始化
      self:_setState(STATE.TITLE, "boot done by timeout")
    end
    return
  end

  if self.state == STATE.TITLE then
    -- 使用状态字节检测是否已进入选人（备用）
    if stateVal == (sv.select or 4) then
      self:_setState(STATE.BOTH_START_PRESS, "skip to start (already in select)")
    elseif self.stateFrame >= 120 then  -- 等待 120 帧 (~2秒) 让标题画面完全加载
      self:_setState(STATE.COIN_PRESS, "insert coin")
    end
    return
  end

  if self.state == STATE.COIN_PRESS then
    -- KOF97 在 Free Play / VS Mode 下不需要投币，直接跳过
    self:_setState(STATE.COIN_WAIT, "skip coin for KOF97 VS Mode")
    return
  end

  if self.state == STATE.COIN_WAIT then
    -- 直接按 P1 Start 进入游戏
    if self.stateFrame >= 1 then
      self:_setState(STATE.BOTH_START_PRESS, "press P1 start only")
    end
    return
  end

  if self.state == STATE.BOTH_START_PRESS then
    -- 按 P1 Start + P1 A 5帧（KOF97 标题画面需要 Start + A 进入选人）
    self:_press({"START", "BUTTON1"}, 1, 5)
    if self.stateFrame >= 5 then
      self:_releaseAll()
      self:_setState(STATE.BOTH_START_WAIT, "P1 start+A released")
    end
    return
  end

  if self.state == STATE.BOTH_START_WAIT then
    -- 检测是否已进入 VS Mode
    if not self:_isVsMode() then
      -- 不是 VS Mode，尝试内存写入强制 VS Mode
      debugLog("[EntryKof97] 未检测到 VS Mode，尝试强制写入")
      self:_ensureVsMode()
      -- 重新按 P2 Start + P2 A 尝试加入
      if self.stateFrame % 15 == 0 then
        self:_press({"START", "BUTTON1"}, 2, 10)
        debugLog("[EntryKof97] 补按 P2 Start+A 尝试加入 VS Mode")
      end
    end
    
    -- 使用 time > 0 检测是否已进入选人/战斗（状态字节不可靠）
    local time, p1Hp, p2Hp = self:_readBattleSignals()
    if time and time > 0 then
      self:_releaseAll()
      self:_setState(STATE.SELECT_RANDOM, "time > 0, skip to select")
      return
    end
    
    -- 使用状态字节检测（备用）
    if stateVal == (sv.select or 4) then
      self:_setState(STATE.SELECT_RANDOM, "state shows select, random select now")
      return
    end
    
    -- 超时：300帧(~5秒)后仍无法进入，尝试按 A 键或重置
    if self.stateFrame >= 300 then
      debugLog("[EntryKof97] BOTH_START_WAIT 超时，尝试按 A 键")
      self:_press({"BUTTON1"}, 1, 5)
      self:_press({"BUTTON1"}, 2, 5)
      if self.stateFrame >= 310 then
        debugLog("[EntryKof97] A 键无效，重置状态机")
        self:_releaseAll()
        self:_setState(STATE.TITLE, "reset to title")
      end
      return
    end
    
    -- 持续按 P1 Start+A + P2 Start+A，直到进入选人或超时
    if self.stateFrame % 10 == 0 then
      self:_press({"START", "BUTTON1"}, 1, 5)
      self:_press({"START", "BUTTON1"}, 2, 5)
      debugLog("[EntryKof97] 持续按 P1+P2 Start+A")
    end
    
    -- 使用 time > 0 检测是否已进入选人/战斗（状态字节不可靠）
    local time, p1Hp, p2Hp = self:_readBattleSignals()
    if time and time > 0 then
      self:_releaseAll()
      self:_setState(STATE.SELECT_RANDOM, "time > 0, skip to select")
      return
    end
    
    -- 使用状态字节检测（备用）
    if stateVal == (sv.select or 4) then
      self:_setState(STATE.SELECT_RANDOM, "state shows select, random select now")
      return
    end
    -- 180帧后自动进入选人（避免状态字节失效导致卡住）
    if self.stateFrame >= 180 then
      self:_releaseAll()
      self:_setState(STATE.SELECT_RANDOM, "auto-select + random")
    end
    return
  end

  if self.state == STATE.SELECT_RANDOM then
    -- KOF97 选人阶段：需要选择3个角色 + 顺序
    -- 策略：每6帧随机移动光标+按A确认，每30帧按Start
    local directions = {"UP", "DOWN", "LEFT", "RIGHT"}
    if self.stateFrame % 6 == 0 then
      local dir1 = directions[math.random(1, 4)]
      local dir2 = directions[math.random(1, 4)]
      self:_press({dir1}, 1, 4)
      self:_press({dir2}, 2, 4)
      -- 同时按A键确认选人（每6帧）
      self:_press({"BUTTON1"}, 1, 6)
      self:_press({"BUTTON1"}, 2, 6)
      debugLog("[EntryKof97] 随机移动+按A确认选人")
    end
    -- 每30帧按Start键（可能用于触发角色选择/顺序选择）
    if self.stateFrame % 30 == 0 then
      self:_press({"START"}, 1, 5)
      self:_press({"START"}, 2, 5)
      debugLog("[EntryKof97] 按Start键触发选人")
    end
    -- 使用 time > 0 检测是否已进入战斗（状态字节不可靠）
    local time, p1Hp, p2Hp = self:_readBattleSignals()
    if time and time > 0 and p1Hp and p1Hp > 0 and p2Hp and p2Hp > 0 then
      self.fightConfirmFrames = self.fightConfirmFrames + 1
      if self.fightConfirmFrames >= 30 then
        self:_releaseAll()
        self:_setState(STATE.FIGHT, "time > 0 and hp > 0, fight detected")
        return
      end
    else
      self.fightConfirmFrames = 0
    end
    -- 使用状态字节检测（备用）
    if stateVal == (sv.loading or 6) or stateVal == (sv.fight or 8) then
      self:_releaseAll()
      self:_setState(STATE.FIGHT, "state shows loading/fight")
      return
    end
    -- 增加超时时间到1800帧（30秒），给KOF97选人多留时间
    if self.stateFrame >= 1800 then
      self:_releaseAll()
      self:_setState(STATE.A_WAIT, "random select timeout")
    end
    return
  end

  if self.state == STATE.A_PRESS then
    -- 持续按 A 完成双方选人和确认（后备）
    self:_press({"BUTTON1"}, 1, 10)
    self:_press({"BUTTON1"}, 2, 10)
    -- 使用 time > 0 检测是否已进入战斗（状态字节不可靠）
    local time, p1Hp, p2Hp = self:_readBattleSignals()
    if time and time > 0 and p1Hp and p1Hp > 0 and p2Hp and p2Hp > 0 then
      self.fightConfirmFrames = self.fightConfirmFrames + 1
      if self.fightConfirmFrames >= 30 then
        self:_releaseAll()
        self:_setState(STATE.FIGHT, "time > 0 and hp > 0, fight detected")
        return
      end
    else
      self.fightConfirmFrames = 0
    end
    -- 使用状态字节检测（备用）
    if stateVal == (sv.loading or 6) or stateVal == (sv.fight or 8) then
      self:_releaseAll()
      self:_setState(STATE.FIGHT, "state shows loading/fight")
      return
    end
    if self.stateFrame >= 120 then
      self:_releaseAll()
      self:_setState(STATE.A_WAIT, "confirm released")
    end
    return
  end

  if self.state == STATE.A_WAIT then
    -- 使用 time > 0 检测是否已进入战斗（状态字节不可靠）
    local time, p1Hp, p2Hp = self:_readBattleSignals()
    if time and time > 0 and p1Hp and p1Hp > 0 and p2Hp and p2Hp > 0 then
      self.fightConfirmFrames = self.fightConfirmFrames + 1
      if self.fightConfirmFrames >= 30 then
        self:_setState(STATE.FIGHT, "time > 0 and hp > 0, fight detected")
        return
      end
    else
      self.fightConfirmFrames = 0
    end
    -- 使用状态字节检测（备用）
    if stateVal == (sv.fight or 8) or stateVal == 9 then
      self:_setState(STATE.FIGHT, "state shows fight")
      return
    end
    if self.stateFrame >= 60 then
      self.cycle = self.cycle + 1
      if self.cycle >= self.maxCycles then
        -- 多次尝试失败，尝试 soft reset 跳过 attract
        if not self.fallbackToCpu then
          self.fallbackToCpu = true
          self.cycle = 0
          debugLog("[EntryKof97] 多次尝试失败，执行 soft reset")
          self.input:softReset()
          self:_setState(STATE.IDLE, "soft reset done")
        else
          self.cycle = 0
          self:_setState(STATE.TITLE, "retry after soft reset")
        end
      else
        self:_setState(STATE.TITLE, string.format("retry cycle %d", self.cycle))
      end
    end
    return
  end
end

return EntryKof97
