local exports = {}
exports.name = "debugmemory4"

function exports.startplugin()
  local logFile = "/tmp/mame-debug8.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug4] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug4 启动 ===")

  local machine = nil
  local lastScan = {}

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
      local device = machine.devices[":maincpu"]
      log("device type: " .. type(device))
      log("space type: " .. type(device.spaces["program"]))
      -- 列出输入端口
      log("ioports:")
      local ok, ports = pcall(function()
        local list = {}
        for tag, port in pairs(machine.ioport) do
          table.insert(list, tag .. " type=" .. type(port))
        end
        return list
      end)
      if ok and ports then
        for _, p in ipairs(ports) do log("  " .. p) end
      else
        log("  error: " .. tostring(ports))
      end
    end

    if frameCount == 600 or frameCount == 1200 or frameCount == 1800 or frameCount == 2400 or frameCount == 3000 or frameCount == 3600 then
      log("=== Frame " .. frameCount .. " (" .. (frameCount/60) .. "s) ===")
      -- 扫描 0xFF8000-0xFF9000 范围内的非零地址
      local nonzero = {}
      for addr = 0xFF8000, 0xFF9000, 1 do
        local val = readU8(addr)
        if val and val ~= 0 then
          table.insert(nonzero, string.format("0x%06X=0x%02X", addr, val))
        end
      end
      if #nonzero > 0 then
        log("非零地址 (" .. #nonzero .. "个):")
        for _, item in ipairs(nonzero) do log("  " .. item) end
      else
        log("范围内无非零地址")
      end
      -- 特别关注几个已知地址
      log("已知地址:")
      log("  0xFF83E8 (P1HP): 0x" .. string.format("%02X", readU8(0xFF83E8) or 0))
      log("  0xFF86E8 (P2HP): 0x" .. string.format("%02X", readU8(0xFF86E8) or 0))
      log("  0xFF8450 (P1X):  0x" .. string.format("%02X", readU8(0xFF8450) or 0))
      log("  0xFF8750 (P2X):  0x" .. string.format("%02X", readU8(0xFF8750) or 0))
      log("  0xFF8ABF (State): 0x" .. string.format("%02X", readU8(0xFF8ABF) or 0))
      log("  0xFF805C (P1Char): 0x" .. string.format("%02X", readU8(0xFF805C) or 0))
      log("  0xFF835C (P2Char): 0x" .. string.format("%02X", readU8(0xFF835C) or 0))
      -- 扫描变化地址
      local changes = {}
      for addr = 0xFF8000, 0xFF9000, 1 do
        local val = readU8(addr)
        if val then
          if lastScan[addr] ~= nil and lastScan[addr] ~= val then
            table.insert(changes, string.format("0x%06X: 0x%02X -> 0x%02X", addr, lastScan[addr], val))
          end
          lastScan[addr] = val
        end
      end
      if #changes > 0 then
        log("变化地址 (" .. #changes .. "个):")
        for _, item in ipairs(changes) do log("  " .. item) end
      else
        log("无变化地址")
      end
    end
  end)

  log("=== Debug4 已注册 ===")
end

return exports
