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

-- 加载日志模块
local Logger = require("utils.logger")
local log = Logger.new("automation")

-- 兼容：旧代码调用 debugLog(msg) 等价于 log:info(msg)
local function debugLog(msg) log:info(msg) end

log:info("LuaFighter 自动化脚本加载中")

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
local PhaseDetectors = require("utils.phase-detectors")
local FtgAiArena = require("drivers.ftg-ai-arena")
local EntryKof97 = require("drivers.entry-kof97")

-- ============ 配置 ============
local ROM_NAME = os.getenv("LUAFIGHTER_ROM") or "kof97"
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
local PHASE = PhaseDetectors.PHASE

-- ============ 全局状态 ============
local mem = MemoryReader.new()
local inputCtrl = InputController.new(romConfig)
local ws = WebSocket.new(WS_HOST, WS_PORT, ROOM_ID)
local ftgAi = FtgAiArena.new(romConfig, mem, inputCtrl)
local entryKof97 = IS_NEOGEO and EntryKof97.new(romConfig, mem, inputCtrl) or nil

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
  local ok, tap = pcall(sp.install_read_tap, sp, 0x800030, 0x800031, "luafighter_coin", function(offset, data, mask)
    if coinInjectActive then
      return (data & 0x00FF) | 0x0100
    end
    return data
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
local fightStartFrame = 0
local koConfirmFrames = 0
local phaseDetector = IS_NEOGEO and PhaseDetectors.newNeoGeo(romConfig, mem) or PhaseDetectors.newCps1(romConfig, mem)

-- 策略缓存（按玩家）
local currentStrategy = { [1] = nil, [2] = nil }

-- 阶段平滑：记录最近 N 帧的 phase，取多数作为当前 phase
-- 但支持 fastSwitch：当状态字节明确变化时，立即切换，不等待平滑
local phaseHistory = {}
local PHASE_HISTORY_SIZE = 3  -- 减少平滑窗口，从 12 降到 3（约 50ms 延迟）
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

-- 快速切换：如果最新检测包含 fastSwitch 标志，直接返回
local lastPhaseMeta = nil

-- 关键时序参数
local STARTUP_DELAY = 30
local ATTRACT_END_FRAME = 3600
local PRESS_CYCLE = 120
local PRESS_DURATION = 30
local INJECTION_TIMEOUT = 2100
local NEOGEO_ENTRY_DURATION = 3600  -- Neo Geo 进场按键持续帧数

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

local function detectPhase()
  local phase, meta = phaseDetector.detect(frameCount, fightStartFrame)
  return phase, meta
end

local function sendEvent(eventData)
  eventData.roomId = ROOM_ID
  eventData.timestamp = os.time()
  ws:send(eventData)
end

local function resetInjection()
  started = false
  inputCtrl:clearAllPersistent()
  inputCtrl:resetCpsState()
  if IS_NEOGEO and entryKof97 then
    entryKof97:reset()
  end
  coinInjectActive = false
end

-- ============ 阶段处理 ============

local function handleAttract()
  if IS_NEOGEO then
    -- KOF97 使用独立的确定性进场状态机
    if entryKof97 then
      entryKof97:update(frameCount)
      if entryKof97:isFight() and not started then
        started = true
        debugLog("[Automation] KOF97 进场状态机报告已进入对战")
      end
    end
    return
  end

  -- CPS1：等待 attract demo 结束后的标题画面阶段（实验性，不保证成功）
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
  -- KOF97 的选人由 entry-kof97.lua 统一处理，但在 entry 状态机未进入 FIGHT 时，
  -- 同时启用 ftgAi:randomSelect 作为后备，加速选人过程
  if IS_NEOGEO and entryKof97 then
    if entryKof97:isFight() then
      return  -- entry 已完成，不需要额外处理
    end
    -- entry 尚未完成，同时执行随机选人作为加速后备
    ftgAi:randomSelect(frameCount)
    return
  end

  -- 其他 ROM：使用 FTG AI 的随机选人辅助（随机移动光标 + 确认）
  ftgAi:randomSelect(frameCount)
  if frameCount % 120 == 0 then
    debugLog(string.format("[Automation] 选人: 随机移动并确认 @ F%d", frameCount))
  end
end

local function handleLoading()
  -- 加载中：不做额外操作，等待进入对战
  if frameCount % 60 == 0 then
    debugLog("[Automation] 加载中，等待对战开始")
  end
end

-- 对战阶段 AI 已迁移到 ftg-ai-arena.lua（帧级状态机 + 状态锁定）

local function handleFight()
  -- 使用 FTG AI Arena 帧级状态机：移动/防御/攻击/必杀
  ftgAi:updateFrame(frameCount)

  -- 检测 KO：至少进入对战 60 帧后再判定，避免进场/加载阶段的误触发
  if koDetected then return end
  local inFightFor = frameCount - fightStartFrame
  if inFightFor < 60 then return end

  local stateVal = readU8(romConfig.stateAddress)
  local sv = romConfig.stateValues or {}
  local koState = sv.ko or 10
  local winState = sv.win or 11

  local function declareRoundEnd(winner)
    if winner == 1 then p1Wins = p1Wins + 1 else p2Wins = p2Wins + 1 end
    koDetected = true
    koConfirmFrames = 0
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

  -- 状态字节明确报 KO/Win 且有一方血量归零（或血量锁定模式）
  if stateVal == koState or stateVal == winState then
    if p1Health <= 0 then
      declareRoundEnd(2)
    elseif p2Health <= 0 then
      declareRoundEnd(1)
    elseif romConfig.lockHealth then
      -- 血量锁定模式下无法从血量判断胜者，暂不统计，等阶段切换
      koDetected = true
      return
    end
  end

  -- 血量归零需连续多帧确认，避免内存读取抖动导致误判
  if p1Health <= 0 or p2Health <= 0 then
    koConfirmFrames = koConfirmFrames + 1
  else
    koConfirmFrames = 0
  end
  if koConfirmFrames >= 6 then
    local winner = (p1Health <= 0) and 2 or 1
    declareRoundEnd(winner)
  end
end

local function handleRoundEnd()
  if gameEnded then
    resetInjection()
    return
  end
  -- 游戏未结束，等待自动进入下一回合
  if frameCount % 60 == 0 then
    debugLog(string.format("[Automation] 回合结束画面 Phase=%s P1HP=%d P2HP=%d state=0x%02X", currentPhase, p1Health, p2Health, readU8(romConfig.stateAddress) or 0))
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
        ftgAi:setStrategy(msg.player, msg, frameCount)
        debugLog(string.format("[Automation] 收到策略 player=%d action=%s special=%s",
          msg.player or 0, tostring(msg.action), tostring(msg.specialMove)))
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

  -- 读取并更新游戏阶段（多数表决平滑，但支持 fastSwitch 快速切换）
  local newPhase, meta = detectPhase()
  lastPhaseMeta = meta
  
  -- fastSwitch：状态字节明确变化时，立即切换，不等待平滑
  if meta and meta.fastSwitch then
    if newPhase ~= currentPhase then
      currentPhase = newPhase
      sendEvent({ event = "phase_change", phase = currentPhase, fastSwitch = true })
      debugLog(string.format("[Automation] 阶段快速切换: %s (state=0x%02X)", currentPhase, meta.state or 0))
      
      -- 回到 attract 阶段时重置状态
      if currentPhase == PHASE.ATTRACT then
        inputCtrl:resetCpsState()
        if IS_NEOGEO and entryKof97 then
          entryKof97:reset()
        end
        debugLog("[Automation] Phase -> ATTRACT, state reset")
      end
      
      -- 进入对战阶段时重置 KO 标记并记录对战开始帧
      if currentPhase == PHASE.FIGHT then
        koDetected = false
        koConfirmFrames = 0
        fightStartFrame = frameCount
        roundCount = roundCount + 1
        debugLog(string.format("[Automation] 进入 Round %d (fastSwitch)", roundCount))
      end
    end
  else
    -- 标准平滑：记录历史并多数表决
    table.insert(phaseHistory, 1, newPhase)
    if #phaseHistory > PHASE_HISTORY_SIZE then table.remove(phaseHistory) end
    local smoothedPhase = getMajorityPhase()
    
    if smoothedPhase ~= currentPhase then
      currentPhase = smoothedPhase
      sendEvent({ event = "phase_change", phase = currentPhase })
      debugLog(string.format("[Automation] 阶段平滑切换: %s", currentPhase))
      
      -- 回到 attract 阶段时重置 CPS1 tap 状态，确保下一局能重新安装
      if currentPhase == PHASE.ATTRACT then
        inputCtrl:resetCpsState()
        if IS_NEOGEO and entryKof97 then
          entryKof97:reset()
        end
        debugLog("[Automation] Phase -> ATTRACT, state reset")
      end
      
      -- 进入对战阶段时重置 KO 标记并记录对战开始帧
      if currentPhase == PHASE.FIGHT then
        koDetected = false
        koConfirmFrames = 0
        fightStartFrame = frameCount
        roundCount = roundCount + 1
        debugLog(string.format("[Automation] 进入 Round %d", roundCount))
      end
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
    -- 向 match-manager 发送心跳，避免被判定为无响应
    print("[LuaFighter] heartbeat")
  end
end)

debugLog("LuaFighter 自动化脚本已加载")
debugLog(string.format("ROM=%s platform=%s Room=%s 端口=%d 时序: wait=%dfr inject_start=%dfr",
  ROM_NAME, IS_NEOGEO and "neogeo" or "cps1", ROOM_ID, WS_PORT, STARTUP_DELAY, ATTRACT_END_FRAME))

-- 向 match-manager 报告心跳（stdout 会被 MAME 子进程捕获）
print("[LuaFighter] automation ready")
