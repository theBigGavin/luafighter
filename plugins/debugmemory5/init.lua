local exports = {}
exports.name = "debugmemory5"

function exports.startplugin()
  local logFile = "/tmp/mame-debug9.log"
  local f = io.open(logFile, "w")
  if not f then print("[Debug5] cannot open log"); return end

  local function log(msg)
    f:write(msg .. "\n")
    f:flush()
  end

  log("=== Debug5 启动 ===")

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
    if frameCount == 1 then
      log("=== Frame 1 ===")
      machine = manager.machine
      
      -- 列出 memory shares
      log("memory shares:")
      local ok, shares = pcall(function()
        local list = {}
        for k, v in pairs(machine.memory.shares) do
          table.insert(list, k .. " type=" .. type(v))
        end
        return list
      end)
      if ok and shares then
        for _, s in ipairs(shares) do log("  " .. s) end
      else
        log("  error: " .. tostring(shares))
      end

      -- 列出 memory banks
      log("memory banks:")
      local ok2, banks = pcall(function()
        local list = {}
        for k, v in pairs(machine.memory.banks) do
          table.insert(list, k .. " type=" .. type(v))
        end
        return list
      end)
      if ok2 and banks then
        for _, b in ipairs(banks) do log("  " .. b) end
      else
        log("  error: " .. tostring(banks))
      end

      -- 尝试读取一些 shares
      local ram = machine.memory.shares[":mainram"]
      log("share :mainram type: " .. type(ram or "nil"))
      if ram then
        local okr, vr = pcall(function() return ram:read_u8(0) end)
        log("ram:read_u8(0) ok=" .. tostring(okr) .. " type=" .. type(vr) .. " val=" .. tostring(vr))
      end

      -- 测试不同地址的读取
      log("Address tests:")
      for _, addr in ipairs({0x000000, 0x100000, 0x800000, 0x900000, 0xFF0000, 0xFF8000, 0xFF83E8, 0xF18000, 0xF10000}) do
        local val = readU8(addr)
        log(string.format("  0x%06X: 0x%02X", addr, val or 0))
      end
    end

    if frameCount == 3000 then
      log("=== Frame 3000 (50s) ===")
      -- 大范围扫描 0xF00000-0xFFFFFF 的非零地址
      local nonzero = {}
      for addr = 0xF00000, 0xFFFFFF, 1 do
        local val = readU8(addr)
        if val and val ~= 0 then
          table.insert(nonzero, string.format("0x%06X=0x%02X", addr, val))
          if #nonzero > 50 then break end
        end
      end
      if #nonzero > 0 then
        log("0xF00000-0xFFFFFF 非零地址 (前50个):")
        for _, item in ipairs(nonzero) do log("  " .. item) end
      else
        log("0xF00000-0xFFFFFF 范围内无非零地址")
      end
    end
  end)

  log("=== Debug5 已注册 ===")
end

return exports
