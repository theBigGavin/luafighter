local exports = {}
exports.name = "debugmemory2"

function exports.startplugin()
  local logFile = "/tmp/mame-debug6.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug2] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug 脚本启动 ===")

  local machine = nil

  local function readU8(addr)
    if not machine then
      machine = manager.machine
      if not machine then
        log("[readU8] manager.machine still nil")
        return 0
      end
    end

    local device = machine.devices[":maincpu"]
    if not device then
      log("[readU8] device nil")
      return 0
    end

    local space = nil

    local ok1, s1 = pcall(function() return device.spaces["program"] end)
    if ok1 and s1 then space = s1; log("[readU8] space via ['program'] OK") end

    if not space then
      local ok2, s2 = pcall(function() return device.spaces.program end)
      if ok2 and s2 then space = s2; log("[readU8] space via .program OK") end
    end

    if not space then
      local ok3, s3 = pcall(function() return device.spaces("program") end)
      if ok3 and s3 then space = s3; log("[readU8] space via () OK") end
    end

    if not space then
      local ok4, s4 = pcall(function() return device:get_space("program") end)
      if ok4 and s4 then space = s4; log("[readU8] space via get_space OK") end
    end

    if not space then
      log("[readU8] all space access failed")
      local ok5, spaces_type = pcall(function() return type(device.spaces) end)
      log("  spaces type: " .. tostring(spaces_type or "nil"))
      return 0
    end

    local ok, val = pcall(function() return space:read_u8(addr) end)
    if ok then return val end
    log("[readU8] read_u8 error: " .. tostring(val))
    return 0
  end

  local function logDevices()
    if not machine then
      machine = manager.machine
    end
    if not machine then
      log("[logDevices] machine nil")
      return
    end
    local ok, dev = pcall(function() return machine.devices end)
    if not ok then log("[logDevices] devices error: " .. tostring(dev)); return end
    if not dev then log("[logDevices] devices nil"); return end

    log("[logDevices] 设备列表:")
    local ok2, devs = pcall(function()
      local list = {}
      for tag, device in pairs(dev) do
        table.insert(list, tag)
      end
      return list
    end)
    if ok2 and devs then
      for _, tag in ipairs(devs) do
        log("  " .. tag)
      end
    else
      log("  pairs failed: " .. tostring(devs))
    end
  end

  local function logMemoryInfo()
    if not machine then
      machine = manager.machine
    end
    if not machine then return end

    local device = machine.devices[":maincpu"]
    if not device then
      log("[logMemory] device nil")
      return
    end

    log("[logMemory] device type: " .. type(device))

    local ok, sp = pcall(function() return device.spaces end)
    if not ok then log("[logMemory] spaces error: " .. tostring(sp)); return end
    if not sp then log("[logMemory] spaces nil"); return end

    log("[logMemory] spaces type: " .. type(sp))

    local ok2, iter = pcall(function()
      local items = {}
      for k, v in pairs(sp) do
        table.insert(items, tostring(k) .. "=" .. type(v))
      end
      return items
    end)
    if ok2 and iter then
      log("[logMemory] spaces entries:")
      for _, item in ipairs(iter) do
        log("  " .. item)
      end
    else
      log("[logMemory] pairs failed: " .. tostring(iter))
    end
  end

  local frameCount = 0

  emu.register_periodic(function()
    frameCount = frameCount + 1
    if frameCount == 1 then
      log("=== Frame 1 ===")
      logDevices()
      logMemoryInfo()
    end

    if frameCount <= 5 then
      local state = readU8(0xFF8ABF)
      local p1HP = readU8(0xFF83E8)
      local p2HP = readU8(0xFF86E8)
      local rom0 = readU8(0x000000)
      local ram8000 = readU8(0xFF8000)
      local ram8100 = readU8(0xFF8100)
      log(string.format("Frame=%d State=0x%02X P1HP=%d P2HP=%d ROM0=0x%02X RAM8000=0x%02X RAM8100=0x%02X", frameCount, state, p1HP, p2HP, rom0, ram8000, ram8100))
    end
  end)

  log("=== Debug2 脚本已注册 ===")
end

return exports
