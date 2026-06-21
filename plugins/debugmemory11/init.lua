local exports = {}
exports.name = "debugmemory11"

function exports.startplugin()
  local logFile = "/tmp/mame-debug15.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug11] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug11 启动 ===")

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
    
    if frameCount == 3 then
      log("=== Frame 3 ===")
      machine = manager.machine
      local device = machine.devices[":maincpu"]
      local space = device.spaces["program"]
      
      -- 设置写监视 GFX RAM 0x900000-0x930000
      log("设置写监视 0x900000-0x930001")
      local ok, err = pcall(function()
        space:install_write_tap(0x900000, 0x930001, "gfx_watcher", function(offset, data, mask)
          log(string.format("GFX WRITE: 0x%06X = 0x%02X", offset, data))
        end)
      end)
      log("GFX install_write_tap ok=" .. tostring(ok) .. " err=" .. tostring(err or "nil"))
      
      -- 设置写监视 Work RAM 0xFF0000-0xFF0001
      log("设置写监视 0xFF0000-0xFF0001")
      local ok2, err2 = pcall(function()
        space:install_write_tap(0xFF0000, 0xFF0001, "ram_watcher", function(offset, data, mask)
          log(string.format("RAM WRITE: 0x%06X = 0x%02X", offset, data))
        end)
      end)
      log("RAM install_write_tap ok=" .. tostring(ok2) .. " err=" .. tostring(err2 or "nil"))
    end

    if frameCount % 60 == 0 then
      local sec = frameCount / 60
      local gfx0 = readU8(0x900000) or 0
      local ram0 = readU8(0xFF0000) or 0
      log(string.format("T=%.0fs GFX0=0x%02X RAM0=0x%02X", sec, gfx0, ram0))
    end
  end)

  log("=== Debug11 已注册 ===")
end

return exports
