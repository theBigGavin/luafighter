local exports = {}
exports.name = "debugmemory6"

function exports.startplugin()
  local logFile = "/tmp/mame-debug10.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug6] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug6 启动 ===")

  local machine = nil

  local function readU8(addr)
    if not machine then
      machine = manager.machine
      if not machine then return nil end
    end
    local device = machine.devices[":maincpu"]
    if not device then return nil end
    local space = device.spaces["program"]
    if not space then return nil end
    local ok, val = pcall(function() return space:read_u8(addr) end)
    if ok then return val end
    return nil
  end

  local frameCount = 0
  emu.register_periodic(function()
    frameCount = frameCount + 1
    
    if frameCount == 1 then
      log("=== Frame 1 ===")
      machine = manager.machine
      -- 尝试注入输入
      log("注入输入测试:")
      local ok1, port0 = pcall(function() return machine.ioport[":IN0"] end)
      log("IN0 type: " .. type(port0 or "nil"))
      if port0 then
        local okw = pcall(function() port0:write(0x00) end)
        log("IN0 write ok: " .. tostring(okw))
      end
      local ok2, port2 = pcall(function() return machine.ioport[":IN2"] end)
      log("IN2 type: " .. type(port2 or "nil"))
      if port2 then
        local okw = pcall(function() port2:write(0x00) end)
        log("IN2 write ok: " .. tostring(okw))
      end
    end

    -- 每60帧记录一次
    if frameCount % 60 == 0 then
      local sec = frameCount / 60
      local p1HP = readU8(0xFF83E8) or 0
      local p2HP = readU8(0xFF86E8) or 0
      local state = readU8(0xFF8ABF) or 0
      log(string.format("T=%.0fs P1HP=0x%02X P2HP=0x%02X State=0x%02X", sec, p1HP, p2HP, state))
    end
  end)

  log("=== Debug6 已注册 ===")
end

return exports
