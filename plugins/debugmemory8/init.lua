local exports = {}
exports.name = "debugmemory8"

function exports.startplugin()
  local logFile = "/tmp/mame-debug12.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug8] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug8 启动 ===")

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
  local lastScan = {}

  emu.register_periodic(function()
    frameCount = frameCount + 1
    
    if frameCount == 60 then
      log("=== Frame 60 (1s) ===")
      -- 扫描 0xFF8000-0xFF9000 的变化
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
        log("无变化")
      end
      -- 测试 save state
      log("测试 save state:")
      local ok, err = pcall(function() manager.machine:save("/tmp/sf2ce_test.sta") end)
      log("save ok=" .. tostring(ok) .. " err=" .. tostring(err or "nil"))
    end

    if frameCount % 60 == 0 then
      local sec = frameCount / 60
      local p1HP = readU8(0xFF83E8) or 0
      local p2HP = readU8(0xFF86E8) or 0
      local state = readU8(0xFF8ABF) or 0
      log(string.format("T=%.0fs P1HP=0x%02X P2HP=0x%02X State=0x%02X", sec, p1HP, p2HP, state))
    end
  end)

  log("=== Debug8 已注册 ===")
end

return exports
