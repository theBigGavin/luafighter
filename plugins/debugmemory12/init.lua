local exports = {}
exports.name = "debugmemory12"

function exports.startplugin()
  local logFile = "/tmp/mame-debug16.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug12] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug12 启动 ===")

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
      local addrs = {
        {0xFF02BE, "Select Speed"},
        {0xFF8ABE, "Time (sf2hf)"},
        {0xFF8ABF, "State (sf2ce)"},
        {0xFF83E8, "P1HP (sf2ce)"},
        {0xFF83E9, "P1HP (sf2hf)"},
        {0xFF86E8, "P2HP (sf2ce)"},
        {0xFF86E9, "P2HP (sf2hf)"},
        {0xFF864F, "P1Char (sf2hf)"},
        {0xFF894F, "P2Char (sf2hf)"},
        {0xFF857B, "P1HP2 (sf2hf)"},
        {0xFF887B, "P2HP2 (sf2hf)"},
        {0xFF82DD, "NoWait (sf2hf)"},
      }
      for _, item in ipairs(addrs) do
        local addr, name = item[1], item[2]
        local val = readU8(addr) or 0
        log(string.format("  0x%06X (%s): 0x%02X", addr, name, val))
      end
    end
  end)

  log("=== Debug12 已注册 ===")
end

return exports
