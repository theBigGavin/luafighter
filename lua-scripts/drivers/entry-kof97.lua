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
  A_PRESS = "a_press",
  A_WAIT = "a_wait",
  FIGHT = "fight",
  FAILED = "failed",
}

local DEBUG_LOG = "/tmp/luafighter-debug.log"
local function debugLog(msg)
  local ok, fd = pcall(function() return io.open(DEBUG_LOG, "a") end)
  if ok and fd then
    fd:write(string.format("[%s] [KOF97 Entry] %s\n", os.date("%H:%M:%S"), tostring(msg)))
    fd:flush()
    fd:close()
  end
end

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
  debugLog("KOF97 进场状态机已重置")
end

function EntryKof97:_readBattleSignals()
  local timeAddr = self.config.timeAddr
  local p1HpAddr = self.config.p1HealthAddr
  local p2HpAddr = self.config.p2HealthAddr
  local time = timeAddr and self.mem:readU8(timeAddr) or nil
  local p1Hp = p1HpAddr and self.mem:readU8(p1HpAddr) or nil
  local p2Hp = p2HpAddr and self.mem:readU8(p2HpAddr) or nil
  return time, p1Hp, p2Hp
end

function EntryKof97:_detectFight()
  -- 方法1：通过时间 + 血量（需游戏已进入对战）
  local time, p1Hp, p2Hp = self:_readBattleSignals()
  if time and time > 0 and time <= 96 and p1Hp and p2Hp and p1Hp > 0 and p2Hp > 0 then
    return true
  end
  -- 方法2：通过 stateAddress（Neo Geo BIOS game state byte）
  local stateAddr = self.config.stateAddress
  if stateAddr then
    local sv = self.config.stateValues or {}
    local stateVal = self.mem:readU8(stateAddr)
    if stateVal == (sv.fight or 8) or stateVal == 9 then
      return true
    end
  end
  return false
end

function EntryKof97:_setState(newState, detail)
  if newState ~= self.state then
    debugLog(string.format("状态切换: %s -> %s (frame=%d, cycle=%d, detail=%s)",
      self.state, newState, self.stateFrame, self.cycle, tostring(detail)))
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

  -- 全局优先：检测到对战标志立即成功
  if self:_detectFight() then
    self:_releaseAll()
    self:_setState(STATE.FIGHT, "battle signals detected")
    return
  end

  if self.state == STATE.IDLE then
    self:_setState(STATE.BOOT, "init")
    return
  end

  if self.state == STATE.BOOT then
    -- Universe BIOS 加载时间稍长，等待 300 帧（~5秒）
    if self.stateFrame >= 300 then
      self:_setState(STATE.TITLE, "boot stable")
    end
    return
  end

  if self.state == STATE.TITLE then
    if self.stateFrame == 30 then
      -- 先确认 Universe BIOS 是否在标题画面
      -- Universe BIOS 下 Coin 是独立的 AUDIO_COIN 端口，Start 在 :edge:joy:START
      self:_setState(STATE.COIN_PRESS, "insert coin")
    end
    return
  end

  if self.state == STATE.COIN_PRESS then
    -- Universe BIOS: 给 P1 和 P2 各投一个币（通过 AUDIO_COIN 端口）
    self:_press({"COIN"}, 1, 8)
    self:_press({"COIN"}, 2, 8)
    if self.stateFrame >= 20 then
      self:_releaseAll()
      self:_setState(STATE.COIN_WAIT, "coin released")
    end
    return
  end

  if self.state == STATE.COIN_WAIT then
    if self.stateFrame >= 20 then
      self:_setState(STATE.BOTH_START_PRESS, "press P1+P2 start")
    end
    return
  end

  if self.state == STATE.BOTH_START_PRESS then
    -- 同时按下 P1 Start + P2 Start，持续稍长以确保 VS 模式触发
    self:_press({"START"}, 1, 20)
    self:_press({"START"}, 2, 20)
    if self.stateFrame >= 20 then
      self:_releaseAll()
      self:_setState(STATE.BOTH_START_WAIT, "start released")
    end
    return
  end

  if self.state == STATE.BOTH_START_WAIT then
    -- 等待进入选人/排序画面，期间偶尔补按 A 防止超时
    if self.stateFrame % 20 == 0 then
      self:_press({"BUTTON1"}, 1, 4)
      self:_press({"BUTTON1"}, 2, 4)
    end
    if self.stateFrame >= 90 then
      self:_releaseAll()
      self:_setState(STATE.A_PRESS, "auto-select + confirm")
    end
    return
  end

  if self.state == STATE.A_PRESS then
    -- 持续按 A 完成双方选人和确认
    self:_press({"BUTTON1"}, 1, 6)
    self:_press({"BUTTON1"}, 2, 6)
    if self.stateFrame >= 60 then
      self:_releaseAll()
      self:_setState(STATE.A_WAIT, "confirm released")
    end
    return
  end

  if self.state == STATE.A_WAIT then
    -- 等待战斗加载完成（可达 120 帧 = 2秒）
    -- 如果 _detectFight() 成功会提前退出
    if self.stateFrame >= 120 then
      self.cycle = self.cycle + 1
      if self.cycle >= self.maxCycles then
        if not self.fallbackToCpu then
          self.fallbackToCpu = true
          self.cycle = 0
          self:_setState(STATE.TITLE, "switch to CPU fallback")
        else
          self.cycle = 0
          self:_setState(STATE.TITLE, "retry CPU fallback")
        end
      else
        self:_setState(STATE.TITLE, string.format("retry cycle %d", self.cycle))
      end
    end
    return
  end
end

return EntryKof97
