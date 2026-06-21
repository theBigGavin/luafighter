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
  local ok, val = pcall(function() return space:read_u8(addrNum) end)
  if ok then return val end
  return nil
end

function MemoryReader:readU16(addr)
  local space = getSpace()
  if not space then return nil end
  local addrNum = hexToNum(addr)
  local ok, val = pcall(function() return space:read_u16(addrNum) end)
  if ok then return val end
  -- 降级：读取两个字节拼接
  local lo = self:readU8(addrNum)
  if lo == nil then return nil end
  local hi = self:readU8(addrNum + 1)
  if hi == nil then return nil end
  return lo + hi * 256
end

function MemoryReader:readS16(addr)
  local val = self:readU16(addr)
  if val == nil then return nil end
  if val > 32767 then val = val - 65536 end
  return val
end

function MemoryReader:readU32(addr)
  local lo = self:readU16(addr)
  if lo == nil then return nil end
  local hi = self:readU16(addr + 2)
  if hi == nil then return nil end
  return lo + hi * 65536
end

return MemoryReader
