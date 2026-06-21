local exports = {}
exports.name = "coinspam"
exports.version = "1.0"

function exports.startplugin()
  local logFile = "/tmp/mame-compare.log"
  local function log(msg)
    local f = io.open(logFile, "a")
    if f then f:write(msg .. "\n"); f:flush(); f:close() end
  end
  
  local function getSpace()
    local m = manager.machine
    if not m then return nil end
    local d = m.devices[":maincpu"]
    if not d then return nil end
    local s = d.spaces and (d.spaces["program"] or d.spaces[0])
    return s
  end
  
  local function readAll(space, fname)
    local f = io.open(fname, "w")
    for a = 0xFF0000, 0xFFFFFF do
      local o, v = pcall(function() return space:read_u8(a) end)
      if o and v and v > 0 then
        f:write(string.format("%06X %02X\n", a, v))
      end
    end
    f:close()
  end
  
  log("=== Compare Scanner ===")
  
  local frame = 0
  local scanned = false
  
  emu.register_periodic(function()
    frame = frame + 1
    
    if frame == 60 and not scanned then
      local space = getSpace()
      if space then
        log("Frame 60: dumping...")
        readAll(space, "/tmp/mame-dump-60.txt")
        log("Frame 60 done")
      end
    end
    
    if frame == 600 and not scanned then
      local space = getSpace()
      if space then
        log("Frame 600: dumping...")
        readAll(space, "/tmp/mame-dump-600.txt")
        log("Frame 600 done - comparing...")
        
        -- Compare: find addresses that CHANGED between frame 60 and 600
        local f60 = {}
        for line in io.lines("/tmp/mame-dump-60.txt") do
          local addr, val = line:match("(%x+) (%x+)")
          if addr then f60[tonumber(addr, 16)] = tonumber(val, 16) end
        end
        
        local changed = {}
        local f600 = io.open("/tmp/mame-dump-600.txt", "r")
        for line in f600:lines() do
          local addr, val = line:match("(%x+) (%x+)")
          if addr then
            local a = tonumber(addr, 16)
            local v = tonumber(val, 16)
            if f60[a] and f60[a] ~= v then
              changed[a] = {f60[a], v}
            elseif not f60[a] then
              -- New at frame 600
              changed[a] = {0, v}
            end
          end
        end
        f600:close()
        
        -- Also check values in f60 that disappeared in f600
        for a, v in pairs(f60) do
          if not changed[a] and io.popen then
            -- No change, not in f600
          end
        end
        
        log(string.format("Changed addresses: %d", #changed))
        local cnt = 0
        for a, vals in pairs(changed) do
          if cnt < 50 then
            log(string.format("  CHANGE %06X: %02X -> %02X", a, vals[1], vals[2]))
            cnt = cnt + 1
          end
        end
        
        -- Also log all frame 600 values in first 3 blocks for inspection
        local f3 = io.open("/tmp/mame-dump-first3-600.txt", "w")
        for a = 0xFF0000, 0xFF03FF do
          local o, v = pcall(function() return space:read_u8(a) end)
          if o and v and v > 0 then
            f3:write(string.format("%06X %02X\n", a, v))
          end
        end
        f3:close()
        
        log("Compare complete")
        scanned = true
      end
    end
  end)
end

return exports
