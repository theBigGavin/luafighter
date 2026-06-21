# LuaFighter 集成指南

> 说明如何将 MAME Lua 插件、Node.js 后端和 React 前端正确连接

---

## 系统概览

LuaFighter 由三个核心层组成：

```
┌─────────────────────────────────────────────────────┐
│  React 前端 (localhost:3000)                         │
│  - Socket.IO 连接到 match-manager (localhost:9003)  │
│  - WebRTC 播放视频流                                   │
│  - HTTP API 创建/管理房间                              │
└─────────────────────────────────────────────────────┘
                          │ Socket.IO (ws://localhost:9003)
                          ▼
┌─────────────────────────────────────────────────────┐
│  Node.js 对局管理器 (localhost:9003)                  │
│  - HTTP API: /api/rooms (CRUD)                       │
│  - Socket.IO: 广播 gameState / roundEnd / gameEnd      │
│  - LuaBridge: 每个房间一个 WebSocket/文件 I/O 服务器    │
│  - MarketClient: 连接行情数据服务 (ws://localhost:9001)  │
└─────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          │               │               │
          ▼               ▼               ▼
  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │ MAME 实例     │ │ Lua 桥接      │ │ 行情数据服务  │
  │ (sf2ce)       │ │ (ws/file)    │ │ (localhost:9001)│
  │ -plugin luafighter│              │                │
  │ 环境变量传递   │ │              │                │
  │  stdout 事件  │ │              │                │
  └──────────────┘ └──────────────┘ └──────────────┘
```

---

## 数据流

### 1. 游戏状态上报（Lua → Node.js → 前端）

```
MAME Lua 脚本
  ├─ 每帧读取内存（血量、坐标、状态）
  ├─ 检测状态变化（attract → select → fight → ko → win）
  ├─ 发送事件：
  │   ├─ {"event": "ready", "rom": "sf2ce"}
  │   ├─ {"event": "update", "p1Hp": 144, "p2Hp": 144, "p1X": 100, "p2X": 300}
  │   ├─ {"event": "phase_change", "phase": "fighting"}
  │   ├─ {"event": "round_end", "winner": 1, "round": 1}
  │   └─ {"event": "game_end", "winner": 1, "p1Wins": 2, "p2Wins": 1}
  │
  ├─ 通信方式：
  │   ├─ 首选：WebSocket (luasocket)
  │   ├─ 降级：文件 I/O (/tmp/luafighter_ipc_<roomId>_in)
  │   └─ 兜底：stdout (LUA_EVENT:{...})
  │
  ▼
LuaBridge (Node.js WebSocketServer / File Polling)
  ├─ 解析 JSON 事件
  ├─ 调用回调：onReady / onStateUpdate / onPhaseChange / onRoundEnd / onGameEnd
  ▼
GameRoom (EventEmitter)
  ├─ 更新游戏状态
  ├─ emit('stateUpdate', gameState)
  ├─ emit('roundEnd', data)
  ├─ emit('gameEnd', data)
  ├─ emit('phaseChange', phase)
  ▼
Socket.IO
  ├─ io.to(roomId).emit('gameState', gameState)
  ├─ io.to(roomId).emit('roundEnd', data)
  ├─ io.to(roomId).emit('gameEnd', data)
  ├─ io.to(roomId).emit('phaseChange', phase)
  ▼
React 前端
  ├─ socket.on('gameState', (state) => setGameState(state))
  ├─ socket.on('roundEnd', (data) => addEvent(`Round ${data.round} 结束`))
  ├─ socket.on('gameEnd', (data) => addEvent(`对局结束`))
  └─ socket.on('phaseChange', (phase) => addEvent(`阶段切换`))
```

### 2. 策略下发（行情 → Node.js → Lua）

```
行情数据服务
  ├─ 生成 MarketTick（模拟或真实数据）
  ├─ 计算 MarketStrength（strengthIndex: -1.0 ~ 1.0）
  └─ WebSocket 广播 tick
      ▼
MarketClient (Node.js)
  ├─ onTick: (strength) => room.onMarketData(strength)
  ▼
GameRoom
  ├─ 如果 roundActive 且 luaBridge 就绪：
  │   ├─ decisionEngine.decide(strength, distance, p1Hp, p2Hp)
  │   └─ 生成 StrategyCommand
  │       {"command": "set_strategy", "player": 1, "action": "aggressive", "moveTendency": {...}}
  │
  ├─ luaBridge.send(strategy)
  ▼
Lua 脚本
  ├─ ws:receive() 读取命令
  ├─ 如果 command == "set_strategy":
  │   └─ currentStrategy = msg
  ├─ 在 handleFight 中：
  │   └─ executeStrategy(currentStrategy) → 设置方向/攻击
```

### 3. 视频流（MAME → FFmpeg → MediaMTX → 前端）

```
MAME 窗口 (640x480)
  ▼
FFmpeg (x11grab / avfoundation)
  ├─ 捕获 MAME 窗口
  ├─ 编码 H.264
  └─ RTMP 推流到 mediamtx:1935/live/<streamId>
      ▼
MediaMTX
  ├─ 接收 RTMP 流
  ├─ 转封装为 WebRTC (WHEP)
  └─ 提供播放端点: http://localhost:8889/<streamId>
      ▼
React 前端
  ├─ fetch(`/api/streams/${roomId}`) 获取 webrtcUrl
  └─ <VideoPlayer webrtcUrl={webrtcUrl} />
```

---

## 启动顺序

正确的启动顺序至关重要：

```bash
# 1. 启动行情数据服务（先启动，等待连接）
npm run dev:market
# [MarketData] WebSocket 启动于 ws://localhost:9001

# 2. 启动对局管理器（连接行情服务，等待前端和 MAME）
npm run dev:manager
# [MatchManager] HTTP API 启动于 http://localhost:9003

# 3. 启动前端（开发服务器）
npm run dev:frontend
# VITE 启动于 http://localhost:3000

# 4. 启动媒体推流（可选，需要 FFmpeg）
npm run dev:media
# [MediaStreamer] 启动于 http://localhost:9005

# 5. 用户通过前端创建房间 → 自动启动 MAME
```

---

## 端口映射

| 服务 | 端口 | 用途 | 配置位置 |
|------|------|------|---------|
| 行情数据 WebSocket | 9001 | Lua/管理器订阅行情 | `packages/shared-types/src/index.ts` |
| 行情数据 HTTP | 9002 | REST API | `packages/market-data/src/index.ts` |
| 对局管理器 HTTP | 9003 | 房间 CRUD | `packages/shared-types/src/index.ts` |
| 对局管理器 Socket.IO | 9003 | 前端事件广播 | `packages/match-manager/src/index.ts` |
| Lua 桥接 | 10000+ | 每个房间一个 | `LUA_WS_PORT_BASE + displayNum` |
| 媒体推流 HTTP | 9005 | 流管理 API | `packages/shared-types/src/index.ts` |
| MediaMTX RTMP | 1935 | FFmpeg 推流 | `docker/docker-compose.yml` |
| MediaMTX WebRTC | 8889 | 浏览器播放 | `docker/docker-compose.yml` |
| 前端开发服务器 | 3000 | Vite dev | `packages/frontend/vite.config.ts` |
| 前端生产 | 80 | Nginx | `docker/docker-compose.yml` |

---

## 环境变量

MAME 进程通过环境变量接收配置：

| 环境变量 | 设置者 | 用途 |
|---------|-------|------|
| `LUAFIGHTER_ROM` | `mame-pool.ts` | ROM 名称（如 `sf2ce`） |
| `LUAFIGHTER_ROOM` | `mame-pool.ts` | 房间 ID（如 `room1`） |
| `LUAFIGHTER_HOST` | `mame-pool.ts` | WebSocket 目标主机（`localhost`） |
| `LUAFIGHTER_PORT` | `mame-pool.ts` | WebSocket 目标端口（`10000+`） |
| `LUAFIGHTER_PATH` | `mame-pool.ts` | 项目根目录（用于 `package.path`） |
| `DISPLAY` | `mame-pool.ts` | Xvfb 显示编号（`:99`） |

---

## API 参考

### HTTP API (对局管理器)

#### 创建房间

```http
POST /api/rooms
Content-Type: application/json

{
  "rom": "sf2ce",
  "symbol": "IF2306",
  "roomId": "room_1"  // 可选，自动生成
}
```

响应：
```json
{
  "success": true,
  "roomId": "room_1",
  "config": {
    "roomId": "room_1",
    "rom": "sf2ce",
    "symbol": "IF2306",
    "display": ":99",
    "streamId": "stream_room_1"
  }
}
```

#### 获取房间列表

```http
GET /api/rooms
```

响应：
```json
{
  "rooms": [
    {
      "roomId": "room_1",
      "state": "running",
      "gameState": { ... },
      "uptime": 120
    }
  ]
}
```

#### 获取房间状态

```http
GET /api/rooms/:roomId
```

#### 获取游戏状态

```http
GET /api/rooms/:roomId/state
```

#### 停止房间

```http
DELETE /api/rooms/:roomId
```

### HTTP API (行情数据)

#### 健康检查

```http
GET /api/health
```

#### 获取支持的代码

```http
GET /api/symbols
```

#### 订阅行情

```http
POST /api/subscribe
Content-Type: application/json

{
  "symbols": ["IF2306", "IC2306"],
  "scenario": "ranging"  // bullish | bearish | volatile | ranging
}
```

### Socket.IO 事件

#### 前端 → 后端

| 事件 | 参数 | 说明 |
|------|------|------|
| `join` | `roomId: string` | 加入房间，接收房间事件 |
| `leave` | `roomId: string` | 离开房间 |

#### 后端 → 前端

| 事件 | 数据 | 说明 |
|------|------|------|
| `joined` | `{ roomId, state: GameState }` | 加入成功，返回当前状态 |
| `gameState` | `GameState` | 游戏状态更新（每帧） |
| `roundEnd` | `{ winner, round, p1Health, p2Health }` | Round 结束 |
| `gameEnd` | `{ winner, p1Wins, p2Wins }` | 对局结束 |
| `phaseChange` | `phase: string` | 阶段切换 |
| `error` | `{ message }` | 错误通知 |

### Lua 事件协议

#### Lua → Node.js

| event | 字段 | 说明 |
|-------|------|------|
| `ready` | `rom: string` | Lua 脚本就绪 |
| `update` | `p1Hp, p2Hp, p1X, p2X, gameState` | 状态更新 |
| `phase_change` | `phase: string` | 阶段切换 |
| `round_end` | `winner, round, p1Health, p2Health` | Round 结束 |
| `game_end` | `winner, p1Wins, p2Wins` | 对局结束 |

#### Node.js → Lua

| command | 字段 | 说明 |
|---------|------|------|
| `set_strategy` | `player, action, moveTendency, specialMove` | 设置策略 |
| `input` | `player, buttons, duration` | 直接输入 |
| `combo` | `player, sequence` | 执行连招 |

---

## 故障排查

### 问题：MAME 启动后 Lua 脚本未加载

**检查**：
1. `plugins/luafighter/plugin.json` 和 `init.lua` 是否存在
2. `mame-pool.ts` 的 `-pluginspath` 是否指向正确的 `plugins/` 目录
3. MAME 日志是否有 `[LuaFighter]` 输出

**解决**：
```bash
# 手动测试 MAME 插件加载
mame sf2ce -window -pluginspath /abs/path/to/plugins -plugin luafighter -skip_gameinfo
```

### 问题：Lua 无法连接后端

**检查**：
1. `lua-bridge.ts` 的 WebSocketServer 是否启动（端口 `10000+`）
2. `websocket.lua` 的 `connect()` 是否成功（查看降级日志）
3. `/tmp/luafighter_ipc_*` 文件是否存在

**解决**：
```bash
# 检查端口监听
lsof -i :10001
# 检查文件
ls -la /tmp/luafighter_ipc_*
```

### 问题：输入注入无效

**检查**：
1. `input-controller.lua` 的 `initPorts` 是否成功（查看日志）
2. `ioport` 端口是否正确获取（`type(port) == "userdata"`）
3. `set_value` 是否被调用（添加 `print` 调试）

**解决**：
```lua
-- 在 updateFrame 中添加调试
for portTag, port in pairs(self.portMap) do
  print("Setting " .. portTag .. " = " .. string.format("0x%02X", self.portValues[portTag]))
end
```

### 问题：内存读取始终为 0

**检查**：
1. 是否处于 attract mode（此时 RAM 未初始化，为 0 是正常的）
2. 地址是否偏移（尝试 `+1` 或 `-1`）
3. `read_u8` 是否返回 `nil`（`spaces` 未就绪）

**解决**：
```bash
# 使用 MAME 调试器验证地址
mame sf2ce -debug
# 在调试器中：
# 1. 进入对战后，查看内存窗口
# 2. 搜索血量值（144 = 0x90）
# 3. 确认地址
```

---

## 扩展开发

### 添加新 ROM 支持

1. 创建 `lua-scripts/rom-configs/<rom>.json`
2. 配置内存地址（使用 MAME 调试器获取）
3. 配置输入映射和招式组合
4. 更新 `PORT_MASKS`（如果硬件不同）

### 添加新行情数据源

1. 实现 `DataSource` 接口：`subscribe(callback)`
2. 在 `market-data/src/index.ts` 中注册
3. 配置 symbol 映射

### 添加新策略

1. 修改 `decision-engine.ts` 的 `decide()` 方法
2. 添加新的 `action` 类型（如 `aggressive`, `defensive`, `neutral`）
3. 在 Lua 端 `executeStrategy()` 中实现对应的输入逻辑

---

## 参考

- [MAME 0.288 兼容性指南](mame-0.288-compatibility.md)
- [MAME Lua 文档](https://docs.mamedev.org/debugger/luaengine.html)
- [Socket.IO 文档](https://socket.io/docs/)
- [MediaMTX 文档](https://github.com/bluenviron/mediamtx)
