local exports = {}
exports.name = "debugmemory7"

function exports.startplugin()
  local logFile = "/tmp/mame-debug11.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug7] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug7 启动 ===")

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
      
      -- 测试 ioport.ports
      log("ioport.ports:")
      local ok, ports = pcall(function()
        local list = {}
        for k, v in pairs(machine.ioport.ports) do
          table.insert(list, k .. " type=" .. type(v))
        end
        return list
      end)
      if ok and ports then
        for _, p in ipairs(ports) do log("  " .. p) end
      else
        log("  error: " .. tostring(ports))
      end
      
      -- 测试特定端口
      local ok2, port0 = pcall(function() return machine.ioport.ports[":IN0"] end)
      log("IN0 type: " .. type(port0 or "nil"))
      if port0 then
        log("IN0 fields:")
        local okf, fields = pcall(function()
          local list = {}
          for k, v in pairs(port0.fields) do
            table.insert(list, k .. " type=" .. type(v))
          end
          return list
        end)
        if okf and fields then
          for _, fld in ipairs(fields) do log("  " .. fld) end
        else
          log("  error: " .. tostring(fields))
        end
        
        -- 测试 write
        local okw = pcall(function() port0:write(0x00) end)
        log("IN0 write(0x00) ok: " .. tostring(okw))
      end
      
      local ok3, port2 = pcall(function() return machine.ioport.ports[":IN2"] end)
      log("IN2 type: " .. type(port2 or "nil"))
      if port2 then
        local okw = pcall(function() port2:write(0x00) end)
        log("IN2 write(0x00) ok: " .. tostring(okw))
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

  log("=== Debug7 已注册 ===")
end

return exports
