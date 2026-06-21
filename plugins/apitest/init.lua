local exports = {}
exports.name = "apitest"
exports.version = "1.0"

function exports.startplugin()
  local logFile = "/tmp/mame-api.log"
  
  local function log(msg)
    local f = io.open(logFile, "a")
    if f then f:write(msg .. "\n"); f:flush(); f:close() end
  end
  
  local function inspect()
    log("=== API Inspection ===")
    
    -- emu methods
    log("emu type: " .. type(emu))
    if emu then
      local methods = {}
      for k, v in pairs(getmetatable(emu).__index or {}) do
        table.insert(methods, tostring(k))
      end
      log("emu methods: " .. table.concat(methods, ", "))
      log("emu.keypost exists: " .. tostring(emu.keypost ~= nil))
    end
    
    local machine = manager.machine
    if not machine then log("machine nil"); return end
    log("machine type: " .. type(machine))
    
    -- ioport
    local ioport = machine.ioport
    log("ioport type: " .. type(ioport))
    if ioport then
      local mt = getmetatable(ioport)
      if mt then
        local methods = {}
        for k, v in pairs(mt.__index or {}) do
          table.insert(methods, tostring(k))
        end
        log("ioport methods: " .. table.concat(methods, ", "))
      end
      log("ioport.ports type: " .. type(ioport.ports))
      if ioport.port then log("ioport.port exists") end
      
      -- Try getting ports
      for _, tag in ipairs({":IN0", ":IN1", ":IN2", "IN0", "IN1", "IN2"}) do
        local ok, p = pcall(function() return ioport:port(tag) end)
        log(string.format("ioport:port('%s') ok=%s type=%s", tag, tostring(ok), type(p)))
        if ok and p then
          local mt2 = getmetatable(p)
          if mt2 and mt2.__index then
            local meths = {}
            for k, v in pairs(mt2.__index) do
              table.insert(meths, tostring(k))
            end
            log("  port methods: " .. table.concat(meths, ", "))
            
            -- Try read
            if mt2.__index.read then
              local ok2, val = pcall(function() return p:read() end)
              if ok2 then log(string.format("  read() = 0x%02X", val)) end
            end
            -- Try write
            if mt2.__index.write then
              log("  has write() - trying...")
              local ok2, err = pcall(function() p:write(0xFF) end)
              log(string.format("  write test: %s %s", tostring(ok2), tostring(err)))
            end
            -- Check set_value
            local has_sv = mt2.__index.set_value ~= nil
            log("  has set_value: " .. tostring(has_sv))
          end
        end
      end
    end
    
    -- input
    local input = machine.input
    log("input type: " .. type(input))
    if input then
      local mt = getmetatable(input)
      if mt then
        local methods = {}
        for k, v in pairs(mt.__index or {}) do
          table.insert(methods, tostring(k))
        end
        log("input methods: " .. table.concat(methods, ", "))
      end
      
      -- Try code_from_token
      if input.code_from_token then
        local ok, code = pcall(function() return input:code_from_token("KEY_1") end)
        log(string.format("code_from_token('KEY_1'): ok=%s type=%s", tostring(ok), type(code)))
      end
      if input.code_press then
        log("input.code_press exists")
      end
      if input.code_release then
        log("input.code_release exists")
      end
    end
  end
  
  local frame = 0
  emu.register_periodic(function()
    frame = frame + 1
    if frame == 5 then inspect() end
    if frame == 10 then log("--- done ---") end
  end)
  
  log("=== API Test Started ===")
end

return exports
