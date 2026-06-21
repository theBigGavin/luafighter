local exports = {}
exports.name = "debugmemory10"

function exports.startplugin()
  local logFile = "/tmp/mame-debug14.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug10] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug10 启动 ===")

  local machine = nil
  local tap = nil

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
    
    if frameCount == 3 then
      log("=== Frame 3 ===")
      machine = manager.machine
      local device = machine.devices[":maincpu"]
      local space = device.spaces["program"]
      
      -- 设置读监视 0xFF83E8
      log("设置读监视 0xFF83E8")
      local ok2, err2 = pcall(function()
        space:install_read_tap(0xFF83E8, 0xFF83E9, "read_watcher", function(offset, data, mask)
          print("[READ] 0x" .. string.format("%06X", offset) .. " = 0x" .. string.format("%02X", data))
          log(string.format("READ: 0x%06X = 0x%02X (mask=0x%02X)", offset, data, mask))
        end)
      end)
      log("install_read_tap ok=" .. tostring(ok2) .. " err=" .. tostring(err2 or "nil"))
      
      -- 设置写监视 0xFF8000-0xFF9000
      log("设置写监视 0xFF8000-0xFF9000")
      local ok, err = pcall(function()
        tap = space:install_write_tap(0xFF8000, 0xFF9001, "watcher", function(offset, data, mask)
          print("[WRITE] 0x" .. string.format("%06X", offset) .. " = 0x" .. string.format("%02X", data))
          log(string.format("WRITE: 0x%06X = 0x%02X (mask=0x%02X)", offset, data, mask))
        end)
      end)
      log("install_write_tap ok=" .. tostring(ok) .. " err=" .. tostring(err or "nil"))
    end

    if frameCount % 60 == 0 then
      local sec = frameCount / 60
      local p1HP = readU8(0xFF83E8) or 0
      log(string.format("T=%.0fs P1HP=0x%02X", sec, p1HP))
    end
  end)

  log("=== Debug10 已注册 ===")
end

return exports
