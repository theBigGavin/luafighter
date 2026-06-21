--[[
  LuaFighter 轻量级 JSON 编码/解码器
  兼容 MAME Lua 环境，不依赖外部库
]]

local JSON = {}

function JSON.encode(obj)
  local t = type(obj)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return obj and "true" or "false"
  elseif t == "number" then
    return tostring(obj)
  elseif t == "string" then
    return "\"" .. obj:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. "\""
  elseif t == "table" then
    local isArray = true
    local maxIndex = 0
    for k, v in pairs(obj) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
        isArray = false
        break
      end
      maxIndex = math.max(maxIndex, k)
    end
    if isArray and maxIndex > 0 then
      local parts = {}
      for i = 1, maxIndex do
        table.insert(parts, JSON.encode(obj[i]))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(obj) do
        if type(k) == "string" then
          table.insert(parts, JSON.encode(k) .. ":" .. JSON.encode(v))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

function JSON.decode(str)
  if cjson and cjson.decode then
    return cjson.decode(str)
  end

  local idx = 1
  local len = #str

  local function peek() return str:sub(idx, idx) end
  local function advance(n) idx = idx + (n or 1) end
  local function skipWs()
    while idx <= len and peek():match("%s") do advance() end
  end

  -- Forward declarations
  local parseValue, parseObject, parseArray

  local function parseString()
    advance() -- skip "
    local out = {}
    while idx <= len do
      local c = peek()
      if c == "\\" then
        advance()
        local esc = peek(); advance()
        if esc == '"' then out[#out+1] = '"'
        elseif esc == '\\' then out[#out+1] = '\\'
        elseif esc == '/' then out[#out+1] = '/'
        elseif esc == 'b' then out[#out+1] = '\b'
        elseif esc == 'f' then out[#out+1] = '\f'
        elseif esc == 'n' then out[#out+1] = '\n'
        elseif esc == 'r' then out[#out+1] = '\r'
        elseif esc == 't' then out[#out+1] = '\t'
        elseif esc == 'u' then
          local hex = str:sub(idx, idx+3); advance(4)
          local code = tonumber(hex, 16)
          if code then
            if code < 0x80 then
              out[#out+1] = string.char(code)
            elseif code < 0x800 then
              out[#out+1] = string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
            elseif code < 0x10000 then
              out[#out+1] = string.char(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F))
            else
              out[#out+1] = string.char(0xF0 | (code >> 18), 0x80 | ((code >> 12) & 0x3F), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F))
            end
          end
        else
          out[#out+1] = esc
        end
      elseif c == '"' then
        advance(); return table.concat(out)
      else
        out[#out+1] = c; advance()
      end
    end
    return table.concat(out)
  end

  parseValue = function()
    skipWs()
    if idx > len then return nil end
    local c = peek()
    if c == '"' then return parseString()
    elseif c == '{' then return parseObject()
    elseif c == '[' then return parseArray()
    elseif c == 't' then advance(4); return true
    elseif c == 'f' then advance(5); return false
    elseif c == 'n' then advance(4); return nil
    else
      local start = idx
      while idx <= len and peek():match("[0-9%.%-eE+]") do advance() end
      return tonumber(str:sub(start, idx-1)) or 0
    end
  end

  parseObject = function()
    advance() -- skip {
    skipWs()
    if peek() == '}' then advance(); return {} end
    local obj = {}
    while true do
      skipWs()
      if peek() ~= '"' then break end
      local key = parseString()
      skipWs()
      if peek() == ':' then advance() end
      obj[key] = parseValue()
      skipWs()
      local c = peek()
      if c == '}' then advance(); return obj end
      if c == ',' then advance() end
    end
    return obj
  end

  parseArray = function()
    advance() -- skip [
    skipWs()
    if peek() == ']' then advance(); return {} end
    local arr = {}
    while true do
      table.insert(arr, parseValue())
      skipWs()
      local c = peek()
      if c == ']' then advance(); return arr end
      if c == ',' then advance() end
    end
    return arr
  end

  return parseValue()
end

return JSON
