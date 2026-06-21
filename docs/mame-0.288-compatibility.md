# MAME 0.288 兼容性指南

> 针对 macOS ARM64 (Apple Silicon) + MAME 0.288 的兼容性修复记录

---

## 环境信息

- **OS**: macOS 15.5 Sequoia, ARM64
- **MAME**: 0.288 (Homebrew: `/opt/homebrew/bin/mame`)
- **Lua**: MAME 内嵌 Lua 5.3 (独立环境，不依赖系统 Lua)

---

## 关键差异

MAME 0.288 相比早期版本（0.2xx 以下）有若干破坏性变更，影响 Lua 插件开发：

| 变更 | 早期版本 | 0.288 | 影响 |
|------|---------|-------|------|
| 帧回调 | `emu.register_frame(fn)` | `emu.register_periodic(fn)` | 脚本不执行 |
| 自启动脚本 | `-autoboot_script` | **移除** | 必须通过 `-plugin` 系统加载 |
| `manager.machine` | `startplugin()` 中可用 | `startplugin()` 中为 `nil`，Frame 3+ 可用 | 延迟初始化崩溃 |
| `luasocket` | 可能可用 | **不可用** | WebSocket 连接失败，需降级到文件 I/O |
| `ioport.ports` | 可遍历表 | `userdata`，`pairs()` 失败 | 输入注入需特殊处理 |

---

## 修复方案详解

### 1. 帧回调：register_frame → register_periodic

**问题**：`emu.register_frame` 在 0.288 中已移除，调用会导致错误。

**修复** (`lua-scripts/drivers/automation.lua`)：

```lua
-- 旧代码（不兼容 0.288）
-- emu.register_frame(function() ... end)

-- 新代码
emu.register_periodic(function()
    frameCount = frameCount + 1
    -- 主循环逻辑
end)
```

**验证**：MAME 日志中应出现 `[LuaFighter] 自动化脚本已加载`，且帧计数器递增。

---

### 2. 自启动脚本：-autoboot_script → -plugin

**问题**：MAME 0.288 macOS 不支持 `-autoboot_script`，必须使用插件系统。

**修复** (`plugins/luafighter/init.lua` + `plugin.json`)：

创建 MAME 插件目录结构：
```
plugins/
└── luafighter/
    ├── plugin.json
    └── init.lua
```

`plugin.json`：
```json
{
  "plugin": "luafighter",
  "description": "LuaFighter automation driver",
  "version": "1.0.0",
  "author": "LuaFighter Team",
  "type": "plugin"
}
```

`init.lua`：
```lua
local exports = {}
exports.name = "luafighter"
function exports.startplugin()
  local pluginDir = "/Users/gavin/playground/gameplay/luafighter/lua-scripts"
  package.path = package.path .. ";" .. pluginDir .. "/?.lua"
  local ok, err = pcall(function()
    require("drivers.automation")
  end)
  if not ok then
    print("[LuaFighter] 加载失败:", err)
  end
end
return exports
```

**启动命令** (`packages/match-manager/src/mame-pool.ts`)：

```typescript
const args = [
  rom,
  '-window',
  '-resolution', '640x480',
  '-noreadconfig',
  '-skip_gameinfo',
  '-pluginspath', pluginPath,  // 指向 plugins/ 目录
  '-plugin', 'luafighter',     // 加载插件
];
```

**注意**：`pluginPath` 必须是绝对路径（通过 `path.resolve()` 解析）。

---

### 3. 延迟初始化：manager.machine

**问题**：`startplugin()` 执行时 `manager.machine` 为 `nil`，`device.spaces["program"]` 和 `ioport.ports` 不可用。

**修复** (`lua-scripts/utils/memory-reader.lua`)：

```lua
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
```

**修复** (`lua-scripts/utils/input-controller.lua`)：

```lua
function InputController:initPorts()
  local machine = manager.machine
  if not machine or not machine.ioport then
    return false
  end
  -- 延迟到 Frame 3+ 执行
  ...
end

function InputController:updateFrame()
  if not self.portsInitialized then
    self:initPorts()
    if not self.portsInitialized then return end
  end
  ...
end
```

**验证**：MAME 日志中 `InputController` 初始化消息应出现在 Frame 3+。

---

### 4. 无 luasocket：WebSocket → 文件 I/O

**问题**：MAME 0.288 的 Lua 环境不包含 `luasocket`，`require("socket")` 失败。

**修复** (`lua-scripts/utils/websocket.lua`)：

连接时多层降级：
1. 尝试 `require("socket")` — 失败
2. 尝试文件 I/O — 成功（创建 `/tmp/luafighter_ipc_*` 文件）
3. 降级到 stdout — 始终成功

**修复** (`packages/match-manager/src/lua-bridge.ts`)：

后端同时支持 WebSocket 和文件 I/O：

```typescript
async start(): Promise<void> {
  this.ensurePipeFiles();  // 预先创建 /tmp/luafighter_ipc_*_in/_out
  
  return new Promise((resolve, reject) => {
    // 10秒超时：如果 WebSocket 未连接，降级到文件 I/O
    const timeout = setTimeout(() => {
      if (!this.isReady) {
        console.log(`[LuaBridge] 降级到文件 I/O`);
        this.startFilePolling();
        this.isReady = true;
        resolve();
      }
    }, 10000);
    
    this.wss = new WebSocketServer({ port: this.port });
    this.wss.on('connection', (ws) => {
      this.ws = ws;
      this.isReady = true;
      clearTimeout(timeout);
      this.stopFilePolling();
      resolve();
    });
  });
}

send(command: LuaCommand): boolean {
  if (this.ws?.readyState === WebSocket.OPEN) {
    this.ws.send(JSON.stringify(command));
    return true;
  } else if (this.filePollingActive) {
    fs.appendFileSync(this.pipeOutPath, JSON.stringify(command) + '\n');
    return true;
  }
  return false;
}
```

**文件通信协议**：
- Lua → Node: 写入 `/tmp/luafighter_ipc_<roomId>_in`（JSON 行）
- Node → Lua: 写入 `/tmp/luafighter_ipc_<roomId>_out`（JSON 行）
- 轮询间隔：100ms

---

### 5. 输入注入：ioport 位掩码

**问题**：`machine.ioport.ports` 是 `userdata`，`pairs()` 遍历失败；`ports[":IN0"]` 在某些情况下返回字符串而非端口对象。

**修复** (`lua-scripts/utils/input-controller.lua`)：

使用 CPS1 端口位掩码直接操作：

```lua
local PORT_MASKS = {
  [":IN0"] = {
    P1_JOYSTICK_RIGHT = 0x01, P1_JOYSTICK_LEFT = 0x02,
    P1_JOYSTICK_DOWN = 0x04, P1_JOYSTICK_UP = 0x08,
    P1_BUTTON1 = 0x10, P1_BUTTON2 = 0x20, P1_BUTTON3 = 0x40,
  },
  [":IN1"] = {
    P2_JOYSTICK_RIGHT = 0x01, P2_JOYSTICK_LEFT = 0x02,
    P2_JOYSTICK_DOWN = 0x04, P2_JOYSTICK_UP = 0x08,
    P2_BUTTON1 = 0x10, P2_BUTTON2 = 0x20, P2_BUTTON3 = 0x40,
  },
  [":IN2"] = {
    P1_COIN = 0x01, P2_COIN = 0x02,
    P1_START = 0x04, P2_START = 0x08,
  },
}

local PORT_DEFAULT = 0xFF  -- IP_ACTIVE_LOW: 1=未激活
```

`initPorts` 尝试多种方法获取端口对象：
1. `ioport.ports[tag]`
2. `ioport:port(tag)`
3. `ioport.find_port(tag)`

`updateFrame` 计算端口值：
```lua
newValues[portTag] = PORT_DEFAULT
for portName, _ in pairs(activeInputs) do
  for portTag, masks in pairs(PORT_MASKS) do
    if masks[portName] then
      newValues[portTag] = newValues[portTag] & ~masks[portName]  -- 激活=0
      break
    end
  end
end
port:set_value(newValues[portTag])
```

---

### 6. 跳过启动提示屏

**问题**：MAME 启动时显示游戏信息屏，需要按任意键继续。

**修复** (`roms/mame.ini`)：

```ini
skip_gameinfo 1
```

或在命令行添加 `-skip_gameinfo`。

---

## 内存地址状态

### sf2ce (Street Fighter II Champion Edition)

| 地址 | 用途 | 来源 | 验证状态 |
|------|------|------|---------|
| `0xFF8ABF` | 游戏状态 | WinKawaks 搜索 | ⚠️ attract=0 已确认（需对战验证 fight=64） |
| `0xFF83E8` | P1 血量 | WinKawaks 搜索 | ⚠️ attract mode 为 0（正常，需对战验证） |
| `0xFF86E8` | P2 血量 | WinKawaks 搜索 | ⚠️ 同上 |
| `0xFF8450` | P1 X 坐标 | WinKawaks 搜索 | ⚠️ 同上 |
| `0xFF8750` | P2 X 坐标 | WinKawaks 搜索 | ⚠️ 同上 |

**说明**：
- `read_u8` 功能已验证（通过 `install_read_tap` 确认 CPU 读取 `0xFF83E8`）
- attract mode 时所有 RAM 为 0 是正常行为（未初始化）
- **需要进入实际对战** 验证 HP 地址是否正确（预期值：144 = 满血）
- FBNeo `sf2hf` 的 P1HP 为 `0xFF83E9`，与 `sf2ce` 的 `0xFF83E8` 接近，说明地址在合理范围内

---

## 调试技巧

### 检查 MAME Lua 环境

在 `plugins/debugmemory/init.lua` 中：

```lua
function exports.startplugin()
  emu.register_periodic(function()
    frame = frame + 1
    if frame == 3 then
      print("type(machine) = " .. type(manager.machine))
      print("type(ioport) = " .. type(manager.machine.ioport))
      print("type(ports) = " .. type(manager.machine.ioport.ports))
      local port = manager.machine.ioport.ports[":IN0"]
      print("port type = " .. type(port))
    end
  end)
end
```

### 检查内存读取

```lua
local space = manager.machine.devices[":maincpu"].spaces["program"]
print("read_u8(0xFF8000) = " .. space:read_u8(0xFF8000))
```

### 检查输入端口

```lua
local ioport = manager.machine.ioport
for tag, _ in pairs({":IN0"=true, ":IN1"=true, ":IN2"=true}) do
  local p = ioport.ports[tag]
  print(tag .. " = " .. type(p))
end
```

---

## 已知限制

1. **内存地址待验证**：`sf2ce` 的 HP 地址基于 WinKawaks 搜索，需要实际对战验证
2. **P1_BUTTON4-6**：`sf2ce` 只有 3 个攻击按钮（轻/中/重），`BUTTON4-6` 映射到 `0x80`（unknown）
3. **输入端口检测**：如果 MAME 的 `ioport` API 进一步变更，可能需要调整 `initPorts` 方法

---

## 参考

- [MAME Lua 引擎文档](https://docs.mamedev.org/debugger/luaengine.html)
- [MAME 插件系统](https://docs.mamedev.org/plugins/index.html)
- [MAME Cheat 系统](https://github.com/mamedev/mame/tree/master/plugins/cheat)
- [FBNeo sf2hf 作弊码](https://github.com/finalburnneo/FBNeo-cheats) — 地址交叉验证参考
