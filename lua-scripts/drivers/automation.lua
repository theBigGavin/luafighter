--[[
  LuaFighter 主驱动脚本
  核心自动化逻辑：状态机、内存读取、输入注入、通信

  重要时序（基于 MAME 0.288 + CPS1 SF2CE):
  ─────────────────────────────────────────────
  MAME 启动 → 游戏 BIOS 初始化 → ROM 加载 → 标题画面
  → attract demo（CPU对战演示）→ 回到标题画面 → 投币 → 选人 → 对战 → 结算

  Neo Geo (KOF97) 时序差异：
  ─────────────────────────────────────────────
  启动后约 10~20 秒即可通过 Coin + Start + A 进入 1P vs CPU。
  不存在 CPS1 的 attract demo 硬币计数器问题，可直接使用 field:set_value。

  install_read_tap 回调中绝对禁止 print() / io.open() / log() 等 I/O 操作，
  否则 MAME 会静默禁用该 tap，后续读取不再经过回调。
]]

-- 调试日志
local LUAFIGHTER_DEBUG_LOG = os.getenv("LUAFIGHTER_DEBUG_LOG") or "/tmp/luafighter-debug.log"
local function debugLog(msg)
  local ok, fd = pcall(function() return io.open(LUAFIGHTER_DEBUG_LOG, "a") end)
  if ok and fd then
    fd:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), tostring(msg)))
    fd:flush()
    fd:close()
  end
end

debugLog("LuaFighter 自动化脚本加载中")

-- 设置 Lua 搜索路径
local scriptDir = debug and debug.getinfo and debug.getinfo(1, "S") and debug.getinfo(1, "S").source
if scriptDir and scriptDir:sub(1,1) == "@" then
  scriptDir = scriptDir:sub(2):match("(.*/)") or ""
end
local projectPath = os.getenv("LUAFIGHTER_PATH") or (scriptDir and scriptDir:match("(.*/)lua%-scripts/")) or "."
package.path = package.path .. ";" .. projectPath .. "/lua-scripts/?.lua"

-- 加载工具模块
local JSON = require("utils.json")
local MemoryReader = require("utils.memory-reader")
local InputController = require("utils.input-controller")
local WebSocket = require("utils.websocket")

-- ============ 配置 ============
local ROM_NAME = os.getenv("LUAFIGHTER_ROM") or "sf2ce"
local ROOM_ID = os.getenv("LUAFIGHTER_ROOM") or "room1"
local WS_HOST = os.getenv("LUAFIGHTER_HOST") or "localhost"
local WS_PORT = tonumber(os.getenv("LUAFIGHTER_PORT")) or 10000
local UPDATE_INTERVAL = tonumber(os.getenv("LUAFIGHTER_UPDATE_INTERVAL")) or 6

-- 加载 ROM 配置
local romConfig = nil
local configPath = "lua-scripts/rom-configs/" .. ROM_NAME .. ".json"
local configFile = io.open(configPath, "r")
if configFile then
  local content = configFile:read("*a")
  configFile:close()
  romConfig = JSON.decode(content) or {}
  if not romConfig or not romConfig.p1HealthAddr then
    debugLog("JSON 解析失败，使用内置默认配置")
    romConfig = nil
  end
else
  debugLog("无法加载 ROM 配置，使用默认配置")
  romConfig = nil
end

-- 默认配置兜底（SF2CE）
romConfig = romConfig or {
  stateAddress = "0xFF8ABF",
  stateValues = { attract = 0, title = 0, select = 60, loading = 60, fight = 2, fight2 = 22, fight3 = 21, win = 21, idle = 21 },
  p1HealthAddr = "0xFF83E9",
  p2HealthAddr = "0xFF86E9",
  p1XAddr = "0xFF8550",
  p2XAddr = "0xFF8850",
  maxHealth = 144,
  p1InputMap = {},
  p2InputMap = {},
  selectConfig = { p1CursorStartX = 0, p1CursorStartY = 0, p2CursorStartX = 7, p2CursorStartY = 0, confirmButton = "BUTTON1", moveDelayFrames = 10 },
  combos = {}
}

local IS_NEOGEO = romConfig.platform == "neogeo"

-- 血量上限前后端统一
local MAX_HEALTH = romConfig.maxHealth or 144

-- ============ 状态常量 ============
local PHASE = {
  ATTRACT = "attract",
  SELECT = "select",
  LOADING = "loading",
  FIGHT = "fight",
  KO = "ko",
  WIN = "win",
  UNKNOWN = "unknown",
}

-- ============ 全局状态 ============
local mem = MemoryReader.new()
local inputCtrl = InputController.new(romConfig)
local ws = WebSocket.new(WS_HOST, WS_PORT, ROOM_ID)

-- CPS1 投币计数器注入 (0x800030)
local coinInjectActive = false
local coinTapInstalled = false
local function installCoinTap()
  if IS_NEOGEO then return end
  if coinTapInstalled then return end
  local m = manager.machine
  if not m or not m.devices then return end
  local cpu = m.devices[":maincpu"]
  if not cpu or not cpu.spaces then return end
  local sp = cpu.spaces["program"]
  if not sp then return end
  local ok, tap = pcall(function()
    return sp:install_read_tap(0x800030, 0x800031, "luafighter_coin", function(offset, data, mask)
      if coinInjectActive then
        return (data & 0x00FF) | 0x0100
      end
      return data
    end)
  end)
  if ok and tap then
    coinTapInstalled = true
    debugLog("[CPS] 投币计数器 tap 已安装 (0x800030)")
  end
end

local currentPhase = PHASE.ATTRACT
local frameCount = 0
local updateCounter = 0
local p1Health = MAX_HEALTH
local p2Health = MAX_HEALTH
local p1X = 0
local p2X = 0
local roundCount = 1
local p1Wins = 0
local p2Wins = 0
local gameEnded = false
local koDetected = false
local started = false

-- 策略缓存（按玩家）
local currentStrategy = { [1] = nil, [2] = nil }

-- 阶段平滑：记录最近 N 帧的 phase，取多数作为当前 phase
local phaseHistory = {}
local PHASE_HISTORY_SIZE = 12
local _stateDebugDone = false

local function getMajorityPhase()
  local counts = {}
  for _, p in ipairs(phaseHistory) do
    counts[p] = (counts[p] or 0) + 1
  end
  local best, bestCount = PHASE.UNKNOWN, 0
  for p, c in pairs(counts) do
    if c > bestCount then
      best = p
      bestCount = c
    end
  end
  return best
end

-- 关键时序参数
local STARTUP_DELAY = 30
local ATTRACT_END_FRAME = 3600
local PRESS_CYCLE = 120
local PRESS_DURATION = 30
local INJECTION_TIMEOUT = 2100
local NEOGEO_ENTRY_DURATION = 1800  -- Neo Geo 进场按键持续帧数

-- ============ 辅助函数 ============

local function readU8(hexStr)
  return mem:readU8(hexStr) or 0
end

local function readS16(hexStr)
  return mem:readS16(hexStr) or 0
end

local function readHealth()
  local p1 = readU8(romConfig.p1HealthAddr)
  local p2 = readU8(romConfig.p2HealthAddr)
  if p1 and p1 > MAX_HEALTH then p1 = MAX_HEALTH end
  if p2 and p2 > MAX_HEALTH then p2 = MAX_HEALTH end
  return p1 or 0, p2 or 0
end

local function readGameState()
  local rawValue = readU8(romConfig.stateAddress)
  local values = romConfig.stateValues or {}
  -- SF2CE CPS1 状态值（基于 MAME 0.288 实测）
  -- 将常见过渡/闲置状态统一归类，避免 unknown 抖动
  if rawValue == (values.attract or 0)
      or rawValue == (values.title or 0)
      or rawValue == 1
      or rawValue == 3
      or rawValue == 17
      or rawValue == 23 then
    return PHASE.ATTRACT
  elseif rawValue == (values.select or 60)
      or rawValue == (values.loading or 60) then
    return PHASE.SELECT
  elseif rawValue == (values.fight or 2)
      or rawValue == (values.fight2 or 22)
      or rawValue == (values.fight3 or 21)
      or rawValue == 33 then
    return PHASE.FIGHT
  elseif rawValue == (values.ko or 21)
      or rawValue == (values.win or 21)
      or rawValue == (values.idle or 21) then
    return PHASE.WIN
  else
    -- 一次性调试：输出未识别的状态值和配置
    if not _stateDebugDone then
      _stateDebugDone = true
      debugLog(string.format("[StateDebug] raw=0x%02X values=%s", rawValue, JSON.encode(values)))
    end
    return PHASE.UNKNOWN
  end
end

-- Neo Geo 阶段检测（KOF97）：通过时间和血量判断
local function detectNeoGeoPhase()
  local time = readU8(romConfig.stateAddress)
  local hp1, hp2 = readHealth()
  -- 对战阶段：倒计时在 1~96 之间且双方有血
  if time > 0 and time <= 96 and hp1 > 0 and hp2 > 0 then
    return PHASE.FIGHT
  end
  -- 选人/标题/加载：倒计时为 0 且双方血量都是 0（内存未初始化）
  if time == 0 and hp1 == 0 and hp2 == 0 then
    return PHASE.ATTRACT
  end
  -- 回合结束：倒计时为 0 且至少一方有血（胜负已分）
  if time == 0 then
    return PHASE.KO
  end
  return PHASE.UNKNOWN
end

local function detectPhase()
  if IS_NEOGEO then
    return detectNeoGeoPhase()
  end
  return readGameState()
end

local function sendEvent(eventData)
  eventData.roomId = ROOM_ID
  eventData.timestamp = os.time()
  ws:send(eventData)
end

local function resetInjection()
  started = false
  inputCtrl:clearAllPersistent()
  coinInjectActive = false
end

-- ============ 阶段处理 ============

local function handleAttract()
  if IS_NEOGEO then
    -- Neo Geo：启动后立刻开始脉冲式按键进场
    if frameCount < STARTUP_DELAY then return end
    local elapsed = frameCount - STARTUP_DELAY
    if elapsed >= NEOGEO_ENTRY_DURATION then
      return
    end
    if not started then
      started = true
      debugLog("[Automation] Neo Geo 进场序列启动")
    end
    local cycle = elapsed % 30
    if cycle < 10 then
      inputCtrl:insertCoin(1)
    elseif cycle >= 10 and cycle < 15 then
      inputCtrl:pressStart(1)
    elseif cycle >= 15 and cycle < 18 then
      inputCtrl:press({"BUTTON1"}, 1, 3)
    end
    return
  end

  -- CPS1：等待 attract demo 结束后的标题画面阶段
  if frameCount < ATTRACT_END_FRAME then
    return
  end

  if not started then
    started = true
    debugLog("[Automation] 开始脉冲式注入投币+Start（CPS1 可能无法响应）")
  end

  local elapsed = frameCount - ATTRACT_END_FRAME
  if elapsed >= 0 and elapsed < INJECTION_TIMEOUT then
    local cycle_frame = elapsed % PRESS_CYCLE
    if cycle_frame == 0 then
      inputCtrl:pressPorts({"P1_COIN_IN0"}, PRESS_DURATION)
      coinInjectActive = true
      if frameCount % 300 == 0 then
        debugLog(string.format("[Automation] 投币 %d帧 @ F%d", PRESS_DURATION, frameCount))
      end
    elseif cycle_frame == PRESS_DURATION then
      coinInjectActive = false
    elseif cycle_frame == PRESS_DURATION + 10 then
      inputCtrl:pressPorts({"P1_START_IN0"}, PRESS_DURATION)
      if frameCount % 300 == 0 then
        debugLog(string.format("[Automation] Start %d帧 @ F%d", PRESS_DURATION, frameCount))
      end
    end
  end

  if elapsed >= INJECTION_TIMEOUT then
    started = false
    -- 超时后等待一个完整周期再重试，避免日志刷屏
    ATTRACT_END_FRAME = frameCount + PRESS_CYCLE
    if frameCount % 600 == 0 then
      debugLog(string.format("[Automation] 注入超时，%d帧后重试", PRESS_CYCLE))
    end
  end
end

local function handleSelect()
  -- 选人阶段：双方同时按确认键选择固定角色
  if frameCount % 120 < 10 then
    inputCtrl:press({"BUTTON1"}, 1, 10)
    inputCtrl:press({"BUTTON1"}, 2, 10)
    if frameCount % 120 == 0 then
      debugLog(string.format("[Automation] 选人: 双方同时按确认 @ F%d", frameCount))
    end
  end
end

local function handleLoading()
  -- 加载中：不做额外操作，等待进入对战
  if frameCount % 60 == 0 then
    debugLog("[Automation] 加载中，等待对战开始")
  end
end

-- 根据策略倾向生成输入
local function applyStrategy(player, strategy)
  if not strategy or not strategy.moveTendency then
    return false
  end

  local mt = strategy.moveTendency
  local otherX = player == 1 and p2X or p1X
  local myX = player == 1 and p1X or p2X
  local distance = math.abs(p1X - p2X)
  local attackDistance = romConfig.attackDistance or 50

  -- 动作风格覆盖
  if strategy.action == "aggressive" then
    -- 进攻：优先接近并攻击
    if myX < otherX then
      inputCtrl:setDirection(player, "right")
    else
      inputCtrl:setDirection(player, "left")
    end
    if distance < attackDistance and frameCount % 30 == (player - 1) * 15 then
      inputCtrl:attack(player, "BUTTON1", 6)
    end
  elseif strategy.action == "defensive" then
    -- 防守：拉开距离，偶尔攻击
    if myX < otherX then
      inputCtrl:setDirection(player, "left")
    else
      inputCtrl:setDirection(player, "right")
    end
    if distance < attackDistance and frameCount % 30 == (player - 1) * 15 then
      inputCtrl:attack(player, "BUTTON2", 6)
    end
  else
    -- 中性：按概率采样移动方向
    local r = math.random()
    if r < mt.forward then
      if myX < otherX then
        inputCtrl:setDirection(player, "right")
      else
        inputCtrl:setDirection(player, "left")
      end
    elseif r < mt.forward + mt.backward then
      if myX < otherX then
        inputCtrl:setDirection(player, "left")
      else
        inputCtrl:setDirection(player, "right")
      end
    elseif r < mt.forward + mt.backward + mt.jump then
      inputCtrl:press({"UP"}, player, 6)
    elseif r < mt.forward + mt.backward + mt.jump + mt.crouch then
      inputCtrl:press({"DOWN"}, player, 6)
    end

    if distance < attackDistance and frameCount % 30 == (player - 1) * 15 then
      inputCtrl:attack(player, "BUTTON1", 6)
    end
  end

  -- 特殊招式
  if strategy.specialMove and romConfig.combos and romConfig.combos[strategy.specialMove] then
    local combo = romConfig.combos[strategy.specialMove]
    for _, step in ipairs(combo) do
      inputCtrl:press(step.buttons, player, step.duration or 6)
    end
  end

  return true
end

local function defaultAI(player)
  local distance = math.abs(p1X - p2X)
  local otherX = player == 1 and p2X or p1X
  local myX = player == 1 and p1X or p2X
  local attackDistance = romConfig.attackDistance or 50

  -- 接近对手
  if myX < otherX then
    inputCtrl:setDirection(player, "right")
  else
    inputCtrl:setDirection(player, "left")
  end

  -- 距离近时攻击
  if distance < attackDistance and frameCount % 30 == (player - 1) * 15 then
    inputCtrl:attack(player, "BUTTON1", 6)
  end

  -- 偶尔跳跃
  if frameCount % 180 == (player - 1) * 90 then
    inputCtrl:press({"UP"}, player, 6)
  end
end

local function handleFight()
  -- 应用策略或默认 AI
  for player = 1, 2 do
    local applied = applyStrategy(player, currentStrategy[player])
    if not applied then
      defaultAI(player)
    end
  end

  -- 检测 KO
  if not koDetected then
    if p1Health <= 0 or p2Health <= 0 then
      koDetected = true
      local winner = (p1Health <= 0) and 2 or 1
      if winner == 1 then p1Wins = p1Wins + 1 else p2Wins = p2Wins + 1 end

      sendEvent({
        event = "round_end",
        winner = winner,
        round = roundCount,
        p1Health = p1Health,
        p2Health = p2Health,
      })

      debugLog(string.format("[Automation] Round %d 结束，胜者 P%d (%d-%d)", roundCount, winner, p1Wins, p2Wins))

      if p1Wins >= 2 or p2Wins >= 2 then
        gameEnded = true
        sendEvent({
          event = "game_end",
          winner = winner,
          p1Wins = p1Wins,
          p2Wins = p2Wins,
        })
        debugLog(string.format("[Automation] 对局结束，最终胜者 P%d", winner))
      end
    end
  end
end

local function handleRoundEnd()
  -- 回合/对局结束画面：等待一段时间后重置以开始下一回合
  if frameCount % 60 == 0 then
    debugLog(string.format("[Automation] 回合结束画面 Phase=%s P1HP=%d P2HP=%d", currentPhase, p1Health, p2Health))
  end

  -- 如果游戏已结束，保持不动；否则等待自动进入下一回合
  if not gameEnded then
    -- 简单等待，游戏会自动进入下一回合
    if currentPhase == PHASE.FIGHT then
      koDetected = false
      roundCount = roundCount + 1
      debugLog(string.format("[Automation] 进入 Round %d", roundCount))
    end
  end
end

-- ============ 主帧回调 ============

emu.register_periodic(function()
  frameCount = frameCount + 1

  -- 第一阶段：等待游戏初始化
  if frameCount < STARTUP_DELAY then
    return
  end

  -- 连接 WebSocket/文件
  if not ws.connected and frameCount % 60 == 0 then
    ws:connect()
    if ws.connected then
      sendEvent({ event = "ready", rom = ROM_NAME })
    end
  end

  -- 接收 WebSocket/文件指令
  if ws.connected and frameCount % 3 == 0 then
    local msg = ws:receive()
    while msg do
      if msg.command == "set_strategy" then
        currentStrategy[msg.player] = msg
      elseif msg.command == "input" then
        inputCtrl:press(msg.buttons, msg.player, msg.duration or 6)
      elseif msg.command == "combo" then
        for _, step in ipairs(msg.sequence) do
          inputCtrl:press(step.buttons, msg.player, step.duration or 6)
        end
      end
      msg = ws:receive()
    end
  end

  -- 安装投币计数器 tap（仅 CPS1）
  if not coinTapInstalled and not IS_NEOGEO then installCoinTap() end

  -- 输入控制器每帧更新（释放过期按键）
  inputCtrl:updateFrame()

  -- 读取健康值和位置（使用有符号坐标，处理环绕/负值）
  p1Health, p2Health = readHealth()
  p1X = readS16(romConfig.p1XAddr)
  p2X = readS16(romConfig.p2XAddr)

  -- 读取并更新游戏阶段（多数表决平滑 + 血量辅助）
  local newPhase = detectPhase()
  -- 血量非零时优先视为对战（SF2CE attract demo 也符合此规律）
  if not IS_NEOGEO and (p1Health > 0 or p2Health > 0) then
    if newPhase == PHASE.UNKNOWN or newPhase == PHASE.ATTRACT then
      newPhase = PHASE.FIGHT
    end
  end
  table.insert(phaseHistory, 1, newPhase)
  if #phaseHistory > PHASE_HISTORY_SIZE then table.remove(phaseHistory) end
  local smoothedPhase = getMajorityPhase()

  if smoothedPhase ~= currentPhase then
    currentPhase = smoothedPhase
    sendEvent({ event = "phase_change", phase = currentPhase })
    debugLog(string.format("[Automation] 阶段切换: %s", currentPhase))

    -- 进入对战阶段时重置 KO 标记
    if currentPhase == PHASE.FIGHT then
      koDetected = false
    end
  end

  -- 阶段处理
  if currentPhase == PHASE.ATTRACT then
    handleAttract()
  elseif currentPhase == PHASE.SELECT then
    handleSelect()
  elseif currentPhase == PHASE.LOADING then
    handleLoading()
  elseif currentPhase == PHASE.FIGHT then
    handleFight()
  elseif currentPhase == PHASE.KO or currentPhase == PHASE.WIN then
    handleRoundEnd()
  end

  -- 定期上报状态
  updateCounter = updateCounter + 1
  if updateCounter >= UPDATE_INTERVAL then
    updateCounter = 0
    sendEvent({
      event = "update",
      p1Hp = p1Health,
      p2Hp = p2Health,
      p1X = p1X,
      p2X = p2X,
      gameState = readU8(romConfig.stateAddress),
    })
  end

  -- 定期摘要日志
  if frameCount % 300 == 0 then
    debugLog(string.format("[Automation] F%d Phase=%s state=0x%02X P1HP=%d P2HP=%d P1X=%d P2X=%d",
      frameCount, currentPhase, readU8(romConfig.stateAddress) or 0, p1Health or 0, p2Health or 0, p1X or 0, p2X or 0))
  end
end)

debugLog("LuaFighter 自动化脚本已加载")
debugLog(string.format("ROM=%s platform=%s Room=%s 端口=%d 时序: wait=%dfr inject_start=%dfr",
  ROM_NAME, IS_NEOGEO and "neogeo" or "cps1", ROOM_ID, WS_PORT, STARTUP_DELAY, ATTRACT_END_FRAME))
