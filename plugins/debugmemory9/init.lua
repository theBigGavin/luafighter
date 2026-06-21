local exports = {}
exports.name = "debugmemory9"

function exports.startplugin()
  local logFile = "/tmp/mame-debug13.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug9] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug9 启动 ===")

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
      
      -- 测试多种方式访问 ioport
      log("ioport access tests:")
      local tests = {
        function() return machine.ioport.ports[":IN0"] end,
        function() return machine.ioport.ports["IN0"] end,
        function() return machine.ioport:find_port(":IN0") end,
        function() return machine.ioport:find_port("IN0") end,
        function() return machine.ioport:port(":IN0") end,
        function() return machine.ioport:port("IN0") end,
      }
      for i, fn in ipairs(tests) do
        local ok, result = pcall(fn)
        log("  test " .. i .. " ok=" .. tostring(ok) .. " type=" .. type(result or "nil"))
        if result and type(result) == "userdata" then
          log("    userdata detected, testing write:")
          local okw = pcall(function() result:write(0x00) end)
          log("    write ok=" .. tostring(okw))
        end
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

  log("=== Debug9 已注册 ===")
end

return exports
