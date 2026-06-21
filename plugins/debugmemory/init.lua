local exports = {}
exports.name = "findcoins"
exports.version = "1.0"

function exports.startplugin()
  local beforeFile = "/tmp/mame-coin-before.txt"
  local afterFile = "/tmp/mame-coin-after.txt"
  
  local function dump(fname)
    local m = manager.machine
    if not m then return end
    local d = m.devices[":maincpu"]
    if not d then return end
    local s = d.spaces["program"]
    if not s then return end
    local f = io.open(fname, "w")
    if not f then return end
    for a = 0xFF0000, 0xFFFFFF do
      local ok, v = pcall(function() return s:read_u8(a) end)
      if ok and v and v > 0 then
        f:write(string.format("%06X %02X\n", a, v))
      end
    end
    f:close()
  end
  
  local frame = 0
  emu.register_periodic(function()
    frame = frame + 1
    if frame == 300 then
      print("[FindCoins] BEFORE dump at frame 300 - please press 5 now!")
      dump(beforeFile)
    end
    if frame == 600 then
      print("[FindCoins] AFTER dump at frame 600")
      dump(afterFile)
      print("[FindCoins] Showing changes:")
      -- Compare and show
      local before, after = {}, {}
      for line in io.lines(beforeFile) do
        local a, v = line:match("(%x+) (%x+)")
        if a then before[a] = v end
      end
      for line in io.lines(afterFile) do
        local a, v = line:match("(%x+) (%x+)")
        if a then
          if not before[a] then
            print(string.format("  NEW 0x%s = 0x%s (new value)", a, v))
          elseif before[a] ~= v then
            print(string.format("  CHG 0x%s: 0x%s -> 0x%s", a, before[a], v))
          end
        end
      end
      for a, v in pairs(before) do
        if not after['0x'..a:sub(3)] and not after[a] then
          -- Check both formats
          local found = false
          for line in io.lines(afterFile) do
            local la, lv = line:match("(%x+) (%x+)")
            if la == a then found = true break end
          end
          if not found then
            print(string.format("  DEL 0x%s = 0x%s (disappeared)", a, v))
          end
        end
      end
      print("[FindCoins] Done")
    end
  end)
end

return exports
