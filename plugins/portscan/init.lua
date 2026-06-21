local exports = {}
exports.name = "portscan"
exports.version = "1.0"

function exports.startplugin()
  local logFile = "/tmp/mame-ports.log"
  
  local function scan()
    local f = io.open(logFile, "a")
    if not f then return end

    f:write("=== Port Scan frame " .. tostring(emu.framecount()) .. " ===\n")
    
    local machine = manager.machine
    if not machine then
      f:write("machine is nil\n"); f:close(); return
    end
    
    local ioport = machine.ioport
    if not ioport then
      f:write("ioport is nil\n"); f:close(); return
    end
    
    f:write("ioport type: " .. type(ioport) .. "\n")
    f:write("ioport.ports type: " .. type(ioport.ports) .. "\n")
    
    if ioport.ports then
      for tag, port in pairs(ioport.ports) do
        local tagStr = tostring(tag)
        local portType = type(port)
        f:write("Port[" .. tagStr .. "] type=" .. portType .. "\n")
        if portType == "userdata" then
          local mt = getmetatable(port)
          if mt and mt.__index then
            local methods = {}
            for k, _ in pairs(mt.__index) do
              table.insert(methods, tostring(k))
            end
            f:write("  methods: " .. table.concat(methods, ", ") .. "\n")
            -- Try reading
            if mt.__index.read then
              local ok, val = pcall(function() return port:read() end)
              if ok then f:write("  read() = " .. tostring(val) .. "\n") end
            end
          end
          f:write("  has set_value: " .. tostring(port.set_value ~= nil) .. "\n")
        end
      end
    end
    
    if ioport.port then
      f:write("ioport.port method exists\n")
      for _, tag in ipairs({"IN0", "IN1", "IN2", ":IN0", ":IN1", ":IN2", "P1", "P2"}) do
        local ok, p = pcall(function() return ioport:port(tag) end)
        f:write("  ioport:port('" .. tag .. "') -> ok=" .. tostring(ok) .. " type=" .. type(p) .. "\n")
        if ok and p and type(p) == "userdata" then
          local mt = getmetatable(p)
          if mt and mt.__index then
            local methods = {}
            for k, _ in pairs(mt.__index) do
              table.insert(methods, tostring(k))
            end
            f:write("    methods: " .. table.concat(methods, ", ") .. "\n")
            -- Try reading it
            if mt.__index.read then
              local ok2, val = pcall(function() return p:read() end)
              if ok2 then f:write("    read() = " .. tostring(val) .. "\n") end
            end
          end
        end
      end
    end
    
    f:flush()
    f:close()
  end
  
  local frameCount = 0
  emu.register_periodic(function()
    frameCount = frameCount + 1
    if frameCount == 3 or frameCount == 10 or frameCount == 30 then
      scan()
    end
  end)
end

return exports
