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
  -- 血量是字节型字段，必须按 U8 读（68k 大端下 U16 会读出 hp*256）
  local p1Hp = p1HpAddr and self.mem:readU8(p1HpAddr) or nil
  local p2Hp = p2HpAddr and self.mem:readU8(p2HpAddr) or nil
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
    -- 等待 MAME/BIOS 初始化（NeoGeo logo → SNK logo → 标题）
    -- 实测（docs/kof97-findings.md）：进场按键必须从启动早期开始，
    -- 错过 title screen 的 START 窗口会长期陷入 attract demo 循环，
    -- 因此 BOOT 等待不宜过长（原 600 帧实测会错过窗口）
    if self.stateFrame % 60 == 0 then
      print(string.format("[EntryKof97-BOOT] stateFrame=%d/120", self.stateFrame))
      debugLog(string.format("[EntryKof97] BOOT progress: %d/120 frames", self.stateFrame))
    end
    if self.stateFrame >= 120 then
      self:_setState(STATE.TITLE, "boot done")
    end
    return
  end

  if self.state == STATE.TITLE then
    -- 使用状态字节检测是否已进入选人（备用）
    if stateVal == (sv.select or 4) then
      self:_setState(STATE.BOTH_START_PRESS, "skip to start (already in select)")
    elseif self.stateFrame >= 30 then
      -- 尽早开始投币脉冲（June 实测：错过标题窗口会长期陷入 attract 循环）
      self:_setState(STATE.COIN_PRESS, "insert coin")
    end
    return
  end

  if self.state == STATE.COIN_PRESS then
    -- June 实测（docs/kof97-findings.md + mvtest7 A/B 验证）：
    -- BIOS 只在标题/attract 的特定窗口接收投币，稀疏单发脉冲会错过；
    -- 必须 30 帧周期持续脉冲（coin 10帧/start 5帧/A 3帧），直到进入选人。
    -- NeoGeo 上 field:set_value 效果只维持一帧，靠 updateFrame 每帧重注。
    local cycle = self.stateFrame % 30
    if cycle < 10 then
      self:_press({"COIN"}, 1, 2)
      self:_press({"COIN"}, 2, 2)
    elseif cycle < 15 then
      self:_press({"START"}, 1, 2)
      self:_press({"START"}, 2, 2)
    elseif cycle < 18 then
      self:_press({"BUTTON1"}, 1, 2)
      self:_press({"BUTTON1"}, 2, 2)
    end

    -- 进入选人检测：状态字节或时间出现
    local time = self:_readBattleSignals()
    if stateVal == (sv.select or 4) or (time and time > 0) then
      self:_releaseAll()
      self:_setState(STATE.SELECT_RANDOM, "select detected during coin mash")
      return
    end
    -- 持续脉冲最多 3600 帧（60秒），之后进选人后备流程
    if self.stateFrame >= 3600 then
      self:_releaseAll()
      self:_setState(STATE.SELECT_RANDOM, "coin mash timeout, fallback to select")
    end
    return
  end

  if self.state == STATE.COIN_WAIT then
    -- 已并入 COIN_PRESS 的持续脉冲，此状态仅作兼容跳转
    self:_setState(STATE.BOTH_START_PRESS, "press P1+P2 start")
    return
  end

  if self.state == STATE.BOTH_START_PRESS then
    -- 投币完成后同时按 P1+P2 Start 进入 1P vs 2P。
    -- 严禁向 stateAddress/battleModeAddr 强制写值：实测证明游戏不会覆盖
    -- 这些字节，写入的伪状态会长期残留并污染阶段检测（fail-open）。
    self:_press({"START"}, 1, 30)
    self:_press({"START"}, 2, 30)
    if self.stateFrame >= 30 then
      self:_releaseAll()
      self:_setState(STATE.BOTH_START_WAIT, "P1+P2 Start released")
    end
    return
  end

  if self.state == STATE.BOTH_START_WAIT then
    -- 检测是否已进入 VS Mode
    if not self:_isVsMode() then
      debugLog("[EntryKof97] 未检测到 VS Mode，尝试强制写入")
      self:_ensureVsMode()
    end
    
    -- 使用 time > 0 检测是否已进入选人/战斗
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
    
    -- 持续按 P1/P2 Start + A，直到进入选人或超时（1800帧=30秒）
    -- 实测（docs/kof97-findings.md）：Start 需要配合 A 才能顺利跳过
    -- 模式/角色选择菜单；P2 Start 在选人前按下才能进入 1P vs 2P；
    -- KOF97 attract demo 可能持续 30-60 秒，需要耐心
    if self.stateFrame % 10 == 0 then
      self:_press({"START"}, 1, 5)
    end
    if self.stateFrame % 10 == 2 then
      self:_press({"START"}, 2, 5)
    end
    if self.stateFrame % 10 == 5 then
      self:_press({"BUTTON1"}, 1, 5)
      self:_press({"BUTTON1"}, 2, 5)
    end
    
    -- 1800帧后自动进入选人（避免无限等待）
    if self.stateFrame >= 1800 then
      self:_releaseAll()
      self:_setState(STATE.SELECT_RANDOM, "auto-select after 1800 frames")
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
