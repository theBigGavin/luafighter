local exports = {}
exports.name = "debugmemory3"

function exports.startplugin()
  local logFile = "/tmp/mame-debug7.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug3] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug3 启动 ===")

  local machine = nil

  local function readU8(addr)
    if not machine then
      machine = manager.machine
      if not machine then return nil, "machine nil" end
    end
    local device = machine.devices[":maincpu"]
    if not device then return nil, "device nil" end
    local space = device.spaces["program"]
    if not space then return nil, "space nil" end
    local ok, val = pcall(function() return space:read_u8(addr) end)
    if ok then return val, nil end
    return nil, "err: " .. tostring(val)
  end

  local frameCount = 0
  emu.register_periodic(function()
    frameCount = frameCount + 1
    if frameCount == 1 then
      log("=== Frame 1 ===")
      machine = manager.machine
      local device = machine.devices[":maincpu"]
      log("device type: " .. type(device))
      log("device spaces type: " .. type(device.spaces))
      local sp = device.spaces["program"]
      log("space type: " .. type(sp))
      local ok, v = pcall(function() return sp:read_u8(0) end)
      log("read_u8(0) ok=" .. tostring(ok) .. " type=" .. type(v) .. " val=" .. tostring(v))
      local ok2, v2 = pcall(function() return sp:read_u8(1) end)
      log("read_u8(1) ok=" .. tostring(ok2) .. " type=" .. type(v2) .. " val=" .. tostring(v2))
      local ok3, v3 = pcall(function() return sp:read_u8(0x100000) end)
      log("read_u8(0x100000) ok=" .. tostring(ok3) .. " type=" .. type(v3) .. " val=" .. tostring(v3))
      local rom = machine.memory.regions[":maincpu"]
      log("rom_region type: " .. type(rom or "nil"))
      if rom then
        local okr, vr = pcall(function() return rom:read_u8(0) end)
        log("rom:read_u8(0) ok=" .. tostring(okr) .. " type=" .. type(vr) .. " val=" .. tostring(vr))
      end
      log("regions:")
      local okr, regions = pcall(function()
        local list = {}
        for k, v in pairs(machine.memory.regions) do
          table.insert(list, k .. " type=" .. type(v))
        end
        return list
      end)
      if okr and regions then
        for _, r in ipairs(regions) do log("  " .. r) end
      else
        log("  error: " .. tostring(regions))
      end
    end

    if frameCount == 60 or frameCount == 120 or frameCount == 180 or frameCount == 300 or frameCount == 600 then
      log("=== Frame " .. frameCount .. " ===")
      machine = manager.machine
      local device = machine.devices[":maincpu"]
      local sp = device.spaces["program"]
      local state = readU8(0xFF8ABF)
      local p1HP = readU8(0xFF83E8)
      local p2HP = readU8(0xFF86E8)
      local p1X = readU8(0xFF8450)
      local p2X = readU8(0xFF8750)
      log(string.format("State=0x%02X P1HP=%d P2HP=%d P1X=%d P2X=%d", state or 0, p1HP or 0, p2HP or 0, p1X or 0, p2X or 0))
      -- 扫描一片 RAM 看是否有非零值
      log("RAM scan 0xFF8000-0xFF8020:")
      for i = 0, 8, 4 do
        local vals = {}
        for j = 0, 3 do
          local okv, vv = pcall(function() return sp:read_u8(0xFF8000 + i + j) end)
          table.insert(vals, string.format("%02X", vv or 0))
        end
        log(string.format("  0x%06X: %s", 0xFF8000 + i, table.concat(vals, " ")))
      end
      log("RAM scan 0xFF83E0-0xFF83F0:")
      for i = 0, 8, 4 do
        local vals = {}
        for j = 0, 3 do
          local okv, vv = pcall(function() return sp:read_u8(0xFF83E0 + i + j) end)
          table.insert(vals, string.format("%02X", vv or 0))
        end
        log(string.format("  0x%06X: %s", 0xFF83E0 + i, table.concat(vals, " ")))
      end
    end

    if frameCount <= 10 then
      local state, e1 = readU8(0xFF8ABF)
      local p1HP, e2 = readU8(0xFF83E8)
      local p2HP, e3 = readU8(0xFF86E8)
      log(string.format("Frame=%d State=%s P1HP=%s P2HP=%s", frameCount, tostring(state), tostring(p1HP), tostring(p2HP)))
    end
  end)

  log("=== Debug3 已注册 ===")
end

return exports
