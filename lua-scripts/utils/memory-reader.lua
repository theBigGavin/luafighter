--[[
  LuaFighter 内存读取封装
  统一封装 MAME 内存读取 API，处理地址转换
  适配 MAME 0.288：device.spaces 在启动时可能延迟初始化
]]

local MemoryReader = {}
MemoryReader.__index = MemoryReader

function MemoryReader.new()
  local obj = {}
  setmetatable(obj, MemoryReader)
  return obj
end

-- 十六进制字符串转数字
local function hexToNum(hexStr)
  if type(hexStr) == "number" then return hexStr end
  if type(hexStr) == "string" then
    return tonumber(hexStr:gsub("0x", ""), 16)
  end
  return 0
end

-- 获取当前可用的地址空间
local function getSpace()
  local machine = manager.machine
  if not machine then return nil end
  local device = machine.devices[":maincpu"]
  if not device then return nil end
  local space = device.spaces and device.spaces["program"]
  if not space then return nil end
  return space
end

function MemoryReader:readU8(addr)
  local space = getSpace()
  if not space then return nil end
  local addrNum = hexToNum(addr)
  local ok, val = pcall(space.read_u8, space, addrNum)
  if ok then return val end
  return nil
end

function MemoryReader:readU16(addr)
  local space = getSpace()
  if not space then return nil end
  local addrNum = hexToNum(addr)
  local ok, val = pcall(space.read_u16, space, addrNum)
  if ok then return val end
  -- 降级：读取两个字节拼接（68000 为大端：低地址字节是高位）
  local hi = self:readU8(addrNum)
  if hi == nil then return nil end
  local lo = self:readU8(addrNum + 1)
  if lo == nil then return nil end
  return hi * 256 + lo
end

function MemoryReader:readS16(addr)
  local val = self:readU16(addr)
  if val == nil then return nil end
  if val > 32767 then val = val - 65536 end
  return val
end

function MemoryReader:readU32(addr)
  -- 68000 大端：地址处为高 16 位
  local hi = self:readU16(addr)
  if hi == nil then return nil end
  local lo = self:readU16(addr + 2)
  if lo == nil then return nil end
  return hi * 65536 + lo
end

function MemoryReader:writeU8(addr, value)
  local space = getSpace()
  if not space then
    print("[MemoryReader-ERROR] getSpace() returned nil, cannot write to " .. tostring(addr))
    return false
  end
  local addrNum = hexToNum(addr)
  if not addrNum then
    print("[MemoryReader-ERROR] hexToNum failed for addr=" .. tostring(addr))
    return false
  end
  print(string.format("[MemoryReader-WRITE] addr=0x%06X value=%d", addrNum, value))
  local ok, err = pcall(space.write_u8, space, addrNum, value)
  if ok then
    print(string.format("[MemoryReader-WRITE-OK] addr=0x%06X value=%d", addrNum, value))
  else
    print("[MemoryReader-WRITE-FAIL] addr=" .. tostring(addr) .. " err=" .. tostring(err))
  end
  return ok
end

return MemoryReader
