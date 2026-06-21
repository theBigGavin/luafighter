local exports = {}
exports.name = "portscan"
exports.version = "1.0"

function exports.startplugin()
  local logFile = "/tmp/mame-ports.log"
  
  -- 延迟初始化，等 manager.machine 可用
  local function scan()
    local f = io.open(logFile, "w")
    if not then return end

    f:write("=== Port Scan ===\n")
    f:write(tostring(os.time()) .. "\n")
    
    local machine = manager.machine
    if not machine then
      f:write("machine is nil\n")
      f:close()
      return
    end
    
    local ioport = machine.ioport
    if not ioport then
      f:write("ioport is nil\n")
      f:close()
      return
    end
    
    f:write("ioport type: " .. type(ioport) .. "\n")
    f:write("ioport.ports type: " .. type(ioport.ports) .. "\n")
    
    if ioport.ports then
      for tag, port in pairs(ioport.ports) do
        local tagStr = tostring(tag)
        local portType = type(port)
        f:write("Port[" .. tagStr .. "] type=" .. portType .. "\n")
        if portType == "userdata" then
          local methods = {}
          for k, v in pairs(getmetatable(port).__index or {}) do
            table.insert(methods, tostring(k))
          end
          f:write("  methods: " .. table.concat(methods, ", ") .. "\n")
          -- Try reading
          if port.read then
            local ok, val = pcall(function() return port:read() end)
            if ok then f:write("  read() = " .. tostring(val) .. "\n") end
          end
          if port.set_value then
            f:write("  has set_value()\n")
          end
        end
      end
    end
    
    if ioport.port then
      f:write("ioport.port method exists\n")
      for _, tag in ipairs({":IN0", "IN0", ":P1", "P1", ":IN2", "IN2", ":IN1", "IN1"}) do
        local ok, p = pcall(function() return ioport:port(tag) end)
        f:write("  ioport:port('" .. tag .. "') -> " .. tostring(ok) .. "/" .. type(p) .. "\n")
        if ok and p then
          local mt = getmetatable(p)
          if mt and mt.__index then
            local methods = {}
            for k, _ in pairs(mt.__index) do
              table.insert(methods, tostring(k))
            end
            f:write("    methods: " .. table.concat(methods, ", ") .. "\n")
          end
        end
      end
    end
    
    if ioport.find_port then
      f:write("ioport.find_port method exists\n")
    end
    
    f:flush()
    f:close()
  end
  
  -- Try at frame 3, 10, 30, 60
  local frameCount = 0
  emu.register_periodic(function()
    frameCount = frameCount + 1
    if frameCount == 3 or frameCount == 10 or frameCount == 30 or frameCount == 60 then
      scan()
    end
  end)
end

return exports
