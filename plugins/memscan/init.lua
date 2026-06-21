local exports = {}
exports.name = "memscan"
exports.version = "1.0"

function exports.startplugin()
  local logFile = "/tmp/mame-memscan2.log"
  local machine = nil

  local function log(msg)
    local f = io.open(logFile, "a")
    if f then f:write(msg .. "\n"); f:flush(); f:close() end
  end

  local function readU8(addr)
    if not machine then machine = manager.machine end
    if not machine then return nil end
    local dev = machine.devices[":maincpu"]
    if not dev then return nil end
    local space = dev.spaces["program"]
    if not space then return nil end
    local ok, val = pcall(function() return space:read_u8(addr) end)
    if ok then return val end
    return nil
  end

  local function readS16(addr)
    local lo = readU8(addr) or 0
    local hi = readU8(addr + 1) or 0
    local val = lo + hi * 256
    if val > 32767 then val = val - 65536 end
    return val
  end

  local function scanAll(tag)
    log("=== " .. tag .. " ===")
    
    -- Scan full 0xFF range for non-zero
    log("Scanning 0xFF0000-0xFFFFFF for non-zero bytes (32KB)...")
    local stats = {}
    for a = 0xFF0000, 0xFFFFFF, 1 do
      local v = readU8(a)
      if v and v > 0 then
        local block = math.floor((a - 0xFF0000) / 0x1000)
        stats[block] = (stats[block] or 0) + 1
      end
    end
    for b = 0, 15 do
      local count = stats[b] or 0
      if count > 0 then
        log(string.format("  FF%Xxxx: %d non-zero bytes", b, count))
      end
    end
    
    -- Check specific addresses that might be health/state
    log("Checking candidate addresses...")
    local candidates = {
      {0xFF0100, "RAM start"},
      {0xFF0000, "RAM start2"},
      {0xFF0030, "Offset 0x30"},
      {0xFF0080, "Offset 0x80"},
    }
    for _, c in ipairs(candidates) do
      local val = readU8(c[1])
      log(string.format("  0x%06X (%s) = 0x%02X", c[1], c[2], val or 0))
    end
    
    -- Check if first few bytes change (indicating code/data)
    local buf = {}
    for a = 0xFF0000, 0xFF001F do
      buf[a - 0xFF0000 + 1] = readU8(a) or 0
    end
    log("First 32 bytes of work RAM:")
    local line = ""
    for i, v in ipairs(buf) do
      line = line .. string.format("%02X ", v)
    end
    log(line)
    
    -- Try reading from cpu_space
    local dev = machine.devices[":maincpu"]
    local cpuSpace = dev and dev.spaces["cpu_space"]
    if cpuSpace then
      log("cpu_space exists, checking addresses...")
      local rom0_v = pcall(function() return cpuSpace:read_u8(0x000000) end)
      log(string.format("  cpu_space[0x000000] ok=%s", tostring(rom0_v)))
      if rom0_v then
        local val = cpuSpace:read_u8(0x000000)
        log(string.format("  cpu_space[0x000000] = 0x%02X", val))
      end
    end
  end

  log("=== Wide MemScan v2 loaded ===")
  
  local frameCount = 0
  emu.register_periodic(function()
    frameCount = frameCount + 1
    if frameCount == 360 then scanAll("Frame 360 (~6s)") end
  end)
end

return exports
