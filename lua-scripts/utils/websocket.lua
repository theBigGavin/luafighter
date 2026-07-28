--[[
  LuaFighter WebSocket 客户端
  提供与 Node.js 对局管理器的通信能力
  
  由于 MAME 的 Lua 环境可能没有原生 socket，
  这里实现多层降级方案：
  1. 优先使用 luasocket（如果可用）
  2. 降级到 io.popen 调用外部程序进行通信
  3. 最终降级到文件 I/O（轮询文件）
]]

 local JSON = require("utils.json")

local WebSocket = {}
WebSocket.__index = WebSocket

local COMM_MODE = "file"  -- 默认文件 I/O，MAME 内嵌 Lua 通常无 luasocket
local pipeFile = "/tmp/luafighter_ipc_"

function WebSocket.new(host, port, roomId)
  local obj = {}
  setmetatable(obj, WebSocket)
  obj.host = host or "localhost"
  obj.port = port or 10000
  obj.roomId = roomId or "default"
  obj.connected = false
  obj.socket = nil
  obj.receiveQueue = {}
  obj.sendQueue = {}
  obj.mode = COMM_MODE
  obj.fileCounter = 0
  obj.readOffset = 0  -- 文件模式增量读取偏移（append-only，不截断）
  return obj
end

function WebSocket:connect()
  -- 尝试 1: 管道文件通信（主路径）
  local pipePath = pipeFile .. self.roomId
  local f = io.open(pipePath .. "_in", "a")
  if f then
    f:close()
    -- 确保输出文件也存在
    local f2 = io.open(pipePath .. "_out", "a")
    if f2 then f2:close() end
    self.mode = "file"
    self.connected = true
    self.pipePath = pipePath
    print("[WebSocket] 使用文件 I/O 通信: " .. pipePath)
    return true
  end

  -- 尝试 2: luasocket（如果可用）
  local ok, socket = pcall(require, "socket")
  if ok then
    local tcp = socket.tcp()
    tcp:settimeout(0.1)
    local ok2, err = tcp:connect(self.host, self.port)
    if ok2 then
      self.socket = tcp
      self.mode = "socket"
      self.connected = true
      print("[WebSocket] 通过 luasocket 连接到 " .. self.host .. ":" .. self.port)
      self:sendHandshake()
      return true
    end
  end

  -- 尝试 3: 标准输出
  self.mode = "stdout"
  self.connected = true
  print("[WebSocket] 降级到 stdout 通信")
  return true
end

function WebSocket:sendHandshake()
  -- 发送 WebSocket HTTP 升级请求（简化）
  if self.mode == "socket" and self.socket then
    local key = "dGhlIHNhbXBsZSBub25jZQ=="  -- 简化 key
    local req = "GET /ws?roomId=" .. self.roomId .. " HTTP/1.1\r\n"
    req = req .. "Host: " .. self.host .. ":" .. self.port .. "\r\n"
    req = req .. "Upgrade: websocket\r\n"
    req = req .. "Connection: Upgrade\r\n"
    req = req .. "Sec-WebSocket-Key: " .. key .. "\r\n"
    req = req .. "Sec-WebSocket-Version: 13\r\n"
    req = req .. "\r\n"
    self.socket:send(req)
  end
end

function WebSocket:send(data)
  if not self.connected then
    return false
  end
  
  local payload = JSON.encode(data)
  
  if self.mode == "socket" and self.socket then
    -- 简化 WebSocket 文本帧发送（非完整实现，但适用于本地内网）
    local frame = string.char(0x81)  -- FIN=1, opcode=text
    local len = #payload
    if len < 126 then
      frame = frame .. string.char(len)
    else
      frame = frame .. string.char(126) .. string.char(math.floor(len / 256)) .. string.char(len % 256)
    end
    frame = frame .. payload
    self.socket:send(frame)
    return true
  elseif self.mode == "file" then
    -- 写入文件
    local f = io.open(self.pipePath .. "_in", "a")
    if f then
      f:write(payload .. "\n")
      f:close()
    end
    return true
  elseif self.mode == "stdout" then
    print("LUA_EVENT:" .. payload)
    return true
  end
  return false
end

function WebSocket:receive()
  if not self.connected then
    return nil
  end

  -- 优先返回已缓存的消息
  if #self.receiveQueue > 0 then
    return table.remove(self.receiveQueue, 1)
  end

  if self.mode == "socket" and self.socket then
    local data, err = self.socket:receive()
    if data and #data > 0 then
      -- 解析 WebSocket 帧（简化）
      local payload = self:parseFrame(data)
      if payload then
        return JSON.decode(payload)
      end
    end
  elseif self.mode == "file" then
    -- append-only 增量读取：记录已读偏移，每轮只读新增内容，
    -- 不截断文件，避免与 Node 端 appendFileSync 竞争导致丢消息
    local outPath = self.pipePath .. "_out"
    local f = io.open(outPath, "r")
    if f then
      local size = f:seek("end") or 0
      local offset = self.readOffset or 0
      if size < offset then
        -- 文件被外部截断/轮转，从头读
        offset = 0
      end
      if size > offset then
        f:seek("set", offset)
        local content = f:read("*a") or ""
        -- 只解析完整行，未写完的半行留到下一轮
        local lastNl = content:match("^.*()\n")
        if lastNl then
          local complete = content:sub(1, lastNl - 1)
          self.readOffset = offset + lastNl
          for line in complete:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$") or line
            if #trimmed > 0 then
              local ok, msg = pcall(JSON.decode, trimmed)
              if ok and msg then
                table.insert(self.receiveQueue, msg)
              end
            end
          end
        end
      end
      f:close()
    end
    if #self.receiveQueue > 0 then
      return table.remove(self.receiveQueue, 1)
    end
  end
  return nil
end

function WebSocket:parseFrame(data)
  -- 极简 WebSocket 帧解析，仅处理文本帧
  if #data < 2 then return nil end
  local byte1 = string.byte(data, 1)
  local byte2 = string.byte(data, 2)
  local opcode = byte1 & 0x0F
  local masked = (byte2 & 0x80) ~= 0
  local len = byte2 & 0x7F
  local pos = 3
  
  if len == 126 then
    len = string.byte(data, 3) * 256 + string.byte(data, 4)
    pos = 5
  elseif len == 127 then
    -- 不支持超长帧
    return nil
  end
  
  if masked then
    local mask = {string.byte(data, pos, pos + 3)}
    pos = pos + 4
    local payload = {}
    for i = 1, len do
      local b = string.byte(data, pos + i - 1)
      table.insert(payload, string.char(b ~ mask[((i - 1) % 4) + 1]))
    end
    return table.concat(payload)
  else
    return string.sub(data, pos, pos + len - 1)
  end
end

function WebSocket:close()
  self.connected = false
  if self.socket then
    self.socket:close()
    self.socket = nil
  end
end

return WebSocket
