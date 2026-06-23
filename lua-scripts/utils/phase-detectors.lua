--[[
  phase-detectors.lua
  平台相关的游戏阶段检测器
  将 CPS1 / Neo Geo 的状态判断逻辑从 automation.lua 中剥离，便于单独维护和扩展。
]]

local PhaseDetectors = {}

PhaseDetectors.PHASE = {
  ATTRACT = "attract",
  SELECT = "select",
  LOADING = "loading",
  FIGHT = "fight",
  KO = "ko",
  WIN = "win",
  UNKNOWN = "unknown",
}

local function clamp(v, min, max)
  if v == nil then return min end
  if v < min then return min end
  if v > max then return max end
  return v
end

-- 通用健康值读取
local function makeHealthReader(config, mem)
  local max = config.maxHealth or 144
  return function()
    local function readU8(addr)
      if not addr then return 0 end
      local ok, val = pcall(mem.readU8, mem, addr)
      if not ok or val == nil then return 0 end
      val = tonumber(val) or 0
      if val > max then val = max end
      return val
    end
    return readU8(config.p1HealthAddr), readU8(config.p2HealthAddr)
  end
end

-- Neo Geo (KOF97) 检测器
-- 由于 Universe BIOS 下部分状态地址在战斗期间保持 0，因此以 time+hp 为主要判据，
-- stateAddress 仅作为辅助/兜底。
function PhaseDetectors.newNeoGeo(config, mem)
  local PHASE = PhaseDetectors.PHASE
  local readHealth = makeHealthReader(config, mem)
  local sv = config.stateValues or {}
  local maxTime = config.maxTime or 99
  local stateAddr = config.stateAddress
  local timeAddr = config.timeAddr

  return {
    detect = function(frameCount, fightStartFrame)
      local hp1, hp2 = readHealth()
      local timeVal = 0
      if timeAddr then
        local ok, t = pcall(mem.readU8, mem, timeAddr)
        if ok and t ~= nil then timeVal = tonumber(t) or 0 end
      end
      local stateVal = 0
      if stateAddr then
        local ok, s = pcall(mem.readU8, mem, stateAddr)
        if ok and s ~= nil then stateVal = tonumber(s) or 0 end
      end

      -- 1) 明确的对战信号：时间正在倒计时 + 双方有血
      if timeVal > 0 and timeVal <= maxTime and hp1 > 0 and hp2 > 0 then
        return PHASE.FIGHT, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end

      -- 2) stateAddress 辅助判断
      if stateVal == (sv.fight or 8) or stateVal == 9 then
        return PHASE.FIGHT, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end
      if stateVal == (sv.ko or 10) then
        return PHASE.KO, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end
      if stateVal == (sv.win or 11) then
        return PHASE.WIN, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end
      if stateVal == (sv.select or 4) or stateVal == (sv.loading or 6) then
        return PHASE.SELECT, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end

      -- 3) 选人/排序阶段：倒计时已开始但血量尚未初始化
      if timeVal > 0 and timeVal <= maxTime and hp1 == 0 and hp2 == 0 then
        return PHASE.SELECT, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end

      -- 4) 时间结束：若已在对战一段时长后时间归零，判为 KO/回合结束；
      --    否则视为选人/加载等过渡阶段。
      if timeVal == 0 then
        local inFightFor = (fightStartFrame and frameCount and frameCount - fightStartFrame) or 0
        if inFightFor > 60 and (hp1 > 0 or hp2 > 0) then
          return PHASE.KO, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
        end
      end

      -- 5) 吸引/标题/闲置
      if stateVal == (sv.attract or 0)
          or stateVal == (sv.title or 1)
          or stateVal == 2
          or stateVal == 3 then
        return PHASE.ATTRACT, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end

      -- 6) 没有任何有效对战信号：血量均为 0 且时间为 0 -> 吸引/标题
      if hp1 == 0 and hp2 == 0 and timeVal == 0 then
        return PHASE.ATTRACT, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
      end

      return PHASE.UNKNOWN, { hp1 = hp1, hp2 = hp2, time = timeVal, state = stateVal }
    end
  }
end

-- CPS1 (SF2CE/SF2) 检测器
-- 基于状态字节映射；血量>0 时优先视为对战，避免 attract demo 被误判。
function PhaseDetectors.newCps1(config, mem)
  local PHASE = PhaseDetectors.PHASE
  local readHealth = makeHealthReader(config, mem)
  local sv = config.stateValues or {}
  local stateAddr = config.stateAddress

  return {
    detect = function(frameCount, fightStartFrame)
      local hp1, hp2 = readHealth()
      local rawValue = 0
      if stateAddr then
        local ok, v = pcall(mem.readU8, mem, stateAddr)
        if ok and v ~= nil then rawValue = tonumber(v) or 0 end
      end

      -- 血量非零时优先视为对战
      if hp1 > 0 or hp2 > 0 then
        return PHASE.FIGHT, { hp1 = hp1, hp2 = hp2, state = rawValue }
      end

      if rawValue == (sv.attract or 0)
          or rawValue == (sv.title or 0)
          or rawValue == (sv.second_attract or 3)
          or rawValue == (sv.second_attract2 or 17)
          or rawValue == 23 then
        return PHASE.ATTRACT, { hp1 = hp1, hp2 = hp2, state = rawValue }
      elseif rawValue == (sv.select or 60)
          or rawValue == (sv.select2 or 59)
          or rawValue == (sv.loading or 60) then
        return PHASE.SELECT, { hp1 = hp1, hp2 = hp2, state = rawValue }
      elseif rawValue == (sv.fight or 2)
          or rawValue == (sv.fight2 or 22)
          or rawValue == (sv.fight3 or 33) then
        return PHASE.FIGHT, { hp1 = hp1, hp2 = hp2, state = rawValue }
      elseif rawValue == (sv.ko or 21)
          or rawValue == (sv.win or 21)
          or rawValue == (sv.idle or 21) then
        return PHASE.WIN, { hp1 = hp1, hp2 = hp2, state = rawValue }
      end

      return PHASE.UNKNOWN, { hp1 = hp1, hp2 = hp2, state = rawValue }
    end
  }
end

return PhaseDetectors
