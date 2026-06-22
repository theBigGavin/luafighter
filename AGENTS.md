# LuaFighter - AI 编码代理指南

> 本文件面向 AI 编码代理。阅读者应对本项目一无所知，请完全依据本文件和实际代码内容进行开发。

## 项目概述

LuaFighter 是一个数据驱动的街机格斗游戏自动对战系统。核心思路是：用实时行情数据（多空强度）驱动 MAME 中格斗游戏的 AI 攻防策略，并通过 WebRTC 低延迟直播到浏览器。

主要流程：

1. `market-data` 生成/接入行情 Tick，计算多空强度指数 `strengthIndex`（-1.0 ~ 1.0）。
2. `match-manager` 维护游戏房间，连接行情服务，把多空强度映射为 1P/2P 的策略指令，通过 Lua 桥接发送给 MAME。
3. MAME 0.288 运行街霸/拳皇 ROM，加载 `plugins/luafighter` 插件，执行 `lua-scripts/drivers/automation.lua`。
4. Lua 脚本读取内存（血量、坐标、状态）、注入输入、上报事件。
5. `media-streamer` 用 FFmpeg 捕获 MAME 画面，RTMP 推送到 MediaMTX，前端通过 WebRTC(WHEP) 播放。
6. React 前端展示房间列表、对战画面、多空数据、血量比分和事件日志。

## 项目结构

```
luafighter/
├── package.json              # npm workspaces 根配置
├── tsconfig.json             # 根 TS 配置（仅作为子包继承模板）
├── .gitignore
├── AGENTS.md                 # 本文件
├── README.md                 # 面向开发者的项目说明（中文）
├── plan.md                   # 项目执行计划
│·
├── packages/                 # Node.js monorepo（npm workspaces）
│   ├── shared-types/         # @luafighter/shared-types：类型定义和端口常量
│   ├── market-data/          # @luafighter/market-data：行情数据服务
│   ├── match-manager/        # @luafighter/match-manager：对局管理器核心
│   ├── media-streamer/       # @luafighter/media-streamer：FFmpeg 推流服务
│   └── frontend/             # @luafighter/frontend：React 18 + Vite 前端
│
├── lua-scripts/              # MAME Lua 运行时脚本
│   ├── drivers/
│   │   ├── automation.lua    # 主驱动脚本（含状态机和输入注入）
│   │   ├── boot.lua          # -autoboot_script 兼容启动脚本
│   │   └── calibration.lua   # 内存地址校准脚本
│   ├── utils/
│   │   ├── input-controller.lua   # 输入控制器（CPS1 read-tap 注入方案）
│   │   ├── memory-reader.lua      # 内存读取封装
│   │   ├── memory-scanner.lua     # 内存扫描工具
│   │   ├── websocket.lua          # Lua 通信客户端
│   │   └── json.lua               # 轻量级 JSON 编解码
│   ├── rom-configs/
│   │   ├── sf2.json          # Street Fighter II (街头霸王2) 配置
│   │   ├── sf2ce.json        # Street Fighter II: Champion Edition 配置
│   │   └── kof97.json        # 拳皇97 配置
│   └── debug-memory.lua      # 内存地址调试验证脚本
│
├── plugins/                  # MAME 插件目录
│   ├── luafighter/           # 主自动化插件入口
│   │   ├── plugin.json
│   │   └── init.lua          # 硬编码了项目路径 /Users/gavin/playground/gameplay/luafighter
│   ├── apitest/              # API 探测插件
│   ├── coinspam/             # 投币测试插件
│   ├── debugmemory/          # 内存/投币变化探测插件
│   ├── debugmemory2~12/      # 多版本内存调试插件
│   ├── memscan/              # 内存扫描插件
│   └── portscan/             # I/O 端口扫描插件
│
├── docker/                   # Docker 部署配置
│   ├── docker-compose.yml
│   ├── Dockerfile.base
│   ├── Dockerfile.frontend
│   ├── mediamtx.yml
│   └── nginx.conf
│
├── scripts/                  # 启动与调试脚本
│   ├── start.sh              # Docker 一键启动
│   ├── test-lua.sh           # 用 -autoboot_script 方式手动测试 Lua
│   └── calibrate.sh          # 启动内存校准脚本
│
├── cfg/                      # MAME 控制器配置
│   ├── default.cfg
│   └── sf2ce.cfg             # 禁用 Coin/Start 物理按键映射
│
├── roms/                     # ROM 目录（gitignored）
│   ├── mame.ini              # MAME 配置：rompath/pluginspath/skip_gameinfo
│   └── ...
│
└── docs/                     # 项目文档
    ├── audit-report.md       # 系统自检报告
    ├── cps1-input-limitation.md   # CPS1 输入注入限制分析
    ├── integration-guide.md       # 集成与 API 参考
    └── mame-0.288-compatibility.md # MAME 0.288 兼容性修复记录
```

## 技术栈

| 层级 | 技术 | 说明 |
|------|------|------|
| 模拟器 | MAME 0.288 | 需要 macOS（Homebrew）或 Linux 安装 |
| 脚本 | Lua 5.3 | MAME 内嵌 Lua，无 luasocket |
| 后端 | Node.js 18+ / TypeScript 5.3 | 严格模式、CommonJS |
| 前端 | React 18 + Vite 5 + TypeScript | 函数组件、Hooks |
| 图表 | ECharts 5 | 实时多空强度趋势图 |
| 通信 | WebSocket (ws) / Socket.IO 4 / Express 4 | |
| 推流 | FFmpeg + MediaMTX | RTMP → WebRTC(WHEP) |
| 数据 | 模拟生成器 | 新浪/东方财富接口仅预留未实现 |

## 端口与服务

| 服务 | 端口 | 用途 | 代码位置 |
|------|------|------|----------|
| market-data WebSocket | 9001 | 行情实时推送 | `packages/market-data/src/index.ts` |
| market-data HTTP | 9002 | REST API（健康检查、订阅、symbol 列表） | `packages/market-data/src/index.ts` |
| match-manager HTTP + Socket.IO | 9003 | 房间 API 和前端事件 | `packages/match-manager/src/index.ts` |
| media-streamer HTTP | 9005 | 推流管理 API | `packages/media-streamer/src/index.ts` |
| LuaBridge WebSocket | 10000+ | 每个房间一个（`LUA_WS_PORT_BASE + displayNum`） | `packages/match-manager/src/lua-bridge.ts` |
| MediaMTX RTMP | 1935 | FFmpeg 推流入口 | `docker/docker-compose.yml` |
| MediaMTX WebRTC | 8889 | 浏览器 WHEP 播放 | `docker/docker-compose.yml` |
| 前端开发服务器 | 3000 | Vite dev | `packages/frontend/vite.config.ts` |
| 前端生产 | 80 | Nginx | `docker/docker-compose.yml` |

注意：`shared-types/src/index.ts` 中虽然声明了 `MANAGER_SOCKET_IO_PORT = 9004`，但实际代码中 Socket.IO 与 HTTP 共享 `MANAGER_HTTP_PORT = 9003`。

## 构建与开发命令

```bash
# 安装依赖
npm install

# 构建所有 TypeScript 包 + Vite 前端
npm run build

# 开发模式（需要 3~4 个终端）
npm run dev:market     # 终端 1：行情数据服务
npm run dev:manager    # 终端 2：对局管理器
npm run dev:frontend   # 终端 3：前端开发服务器
npm run dev:media      # 终端 4：媒体推流服务（可选）

# Docker 一键部署
./scripts/start.sh
```

### 已知问题

- `npm run typecheck`（根目录 `tsc --noEmit`）会失败，因为根 `tsconfig.json` 的 `include` 指向不存在的 `./src`。
  实际类型检查应通过各包自己的 `tsc` 完成，或单独运行 `npm run build`。
- `npm run lint` 会失败，因为项目中没有 `.eslintrc.*` 或 `eslint.config.*` 配置文件。
- 前端构建会产生 CJS 弃用警告和 chunk 过大警告（Vite 5 + Node 24），不影响构建结果。

## 代码组织与模块职责

### packages/shared-types

所有 TypeScript 包共享：
- `MarketTick` / `MarketStrength` / `GameState` / `RoomConfig` / `RomConfig` / `StreamInfo`
- Lua ↔ Node 指令类型：`StrategyCommand` / `InputCommand` / `ComboCommand`
- Lua 事件类型：`LuaReadyEvent` / `LuaStateUpdateEvent` / `LuaRoundEndEvent` / `LuaGameEndEvent` / `LuaPhaseChangeEvent`
- 端口常量

### packages/market-data

- `src/index.ts`：Express HTTP API + WebSocket 服务入口。
- `src/mock-generator.ts`：模拟行情生成器，支持 `bullish | bearish | volatile | ranging` 四种场景。
- `src/strength-calculator.ts`：10 秒滑动窗口 + 成交量加权，输出 `strengthIndex`。
- `src/data-source.ts`：`IDataSource` 抽象 + `MockDataSource`；`SinaDataSource` / `EastMoneyDataSource` 仅预留未实现。

### packages/match-manager

- `src/index.ts`：HTTP API + Socket.IO 服务器；创建/停止房间；转发房间事件。
- `src/mame-pool.ts`：`MamePool` / `MameProcessManager`，启动 MAME 进程并传递环境变量。
- `src/lua-bridge.ts`：每个房间一个 WebSocket 服务器，10 秒未连接则降级到 `/tmp/luafighter_ipc_*` 文件轮询。
- `src/decision-engine.ts`：根据多空强度生成 1P/2P 的策略指令。
- `src/game-room.ts`：`GameRoom` 维护单局生命周期、状态机和事件转发。
- `src/market-client.ts`：连接 `market-data` 的 WebSocket，断线重连。

### packages/media-streamer

- `src/stream-manager.ts`：`FFmpegStreamer` / `StreamManager`，按平台选择输入（macOS `avfoundation`，Linux `x11grab`）。
- `src/index.ts`：HTTP API 控制流生命周期。

### packages/frontend

- `src/App.tsx`：路由（`/` 房间列表，`/room/:roomId` 观看页）。
- `src/pages/RoomList.tsx`：创建房间、轮询房间列表。
- `src/pages/WatchRoom.tsx`：Socket.IO 连接、事件日志、数据可视化。
- `src/components/VideoPlayer.tsx`：WHEP WebRTC 播放器。
- `src/components/ScoreBoard.tsx` / `MarketPanel.tsx` / `StrengthChart.tsx` / `EventLog.tsx`：UI 组件。

### lua-scripts

- `drivers/automation.lua`：主循环，包含 CPS1 投币 tap、状态机、战斗 AI、行情策略接收。
- `utils/input-controller.lua`：CPS1 使用 `install_read_tap` 在 `0x800000-0x800007`（IN1）和 `0x800018-0x80001F`（IN0/DSW）注入输入。
- `utils/memory-reader.lua`：封装 `space:read_u8/u16`。
- `utils/websocket.lua`：通信客户端，依次降级 luasocket → 文件 I/O → stdout。
- `utils/json.lua`：不依赖外部库的 JSON 编解码器。
- `rom-configs/*.json`：每个 ROM 的内存地址、输入映射、选人配置、连招定义。

## 代码风格指南

- **TypeScript**：2 空格缩进，严格模式，ES2022 目标。
  - 类型/接口使用 `PascalCase`。
  - 变量/函数使用 `camelCase`。
  - 包名使用 `@luafighter/<name>`。
- **React**：函数组件 + Hooks，`.tsx` 扩展名。
- **Lua**：2 空格缩进，公共函数使用 `camelCase`。
  - MAME 全局 `emu`、`manager`、`machine` 直接访问。
  - 在 `install_read_tap` 回调中**绝对禁止** `print` / `io.open` / `log` 等 I/O 操作，否则 tap 会被静默禁用。
- **JSON（ROM 配置）**：`snake_case` 键，所有地址值使用十六进制字符串，如 `"0xFF8ABF"`。
- **CSS**：手写样式，暗色主题，无 Tailwind/UI 库。

## 测试与验证

项目目前没有自动化单元测试，所有验证依赖手动/集成测试：

```bash
# 1. 类型与构建
npm run build

# 2. 行情服务健康检查
curl http://localhost:9002/api/health

# 3. 对局管理器健康检查
curl http://localhost:9003/api/health

# 4. 媒体推流健康检查
curl http://localhost:9005/api/health

# 5. 手动加载 MAME 插件（需 ROM）
./scripts/test-lua.sh sf2ce

# 6. 内存地址校准（需 ROM）
./scripts/calibrate.sh sf2ce
```

### ROM 配置验证

新增 ROM 时：

1. 创建 `lua-scripts/rom-configs/<rom>.json`，填写内存地址、输入映射、选人配置、连招。
2. 如果硬件不是 CPS1，需要修改 `utils/input-controller.lua` 的 `PORT_CONFIG` 和注入逻辑。
3. 使用 `debugmemory` 插件或 `./scripts/calibrate.sh` 验证地址正确性。
4. 运行 `./scripts/test-lua.sh <rom>` 验证插件加载和事件上报。

## 部署

### Docker Compose（推荐生产部署）

```bash
./scripts/start.sh
```

等价于：

```bash
cd docker
docker-compose up --build -d
```

访问 `http://localhost`。

### 本地开发

按顺序启动四个服务后，访问 `http://localhost:3000` 创建房间。前端 Vite 会代理 `/api` 和 `/socket.io` 到 `localhost:9003`，代理 `/api/streams` 到 `localhost:9005`。

## 环境变量

| 变量 | 默认值 | 设置位置 | 说明 |
|------|--------|----------|------|
| `ROMS_DIR` | `./roms` | `match-manager/src/index.ts` | ROM 文件目录 |
| `LUA_SCRIPT_PATH` | `lua-scripts/drivers/automation.lua` | `match-manager/src/index.ts` | Lua 驱动脚本路径 |
| `MAME_PATH` | `mame` | `match-manager/src/mame-pool.ts` | MAME 可执行文件 |
| `DISPLAY` | `:99` | `match-manager/src/mame-pool.ts` | Xvfb 显示编号 |
| `MEDIA_MTX_URL` | `rtmp://localhost:1935/live` | `media-streamer/src/stream-manager.ts` | RTMP 推流地址 |
| `LUAFIGHTER_ROM` | `sf2ce` | MAME 进程环境变量 | 当前 ROM |
| `LUAFIGHTER_ROOM` | `room1` | MAME 进程环境变量 | 当前房间 ID |
| `LUAFIGHTER_HOST` / `PORT` | `localhost` / `10000+` | MAME 进程环境变量 | LuaBridge 目标 |
| `LUAFIGHTER_DEBUG_LOG` | `/tmp/luafighter-debug.log` | Lua 脚本 | 调试日志路径 |

## 关键限制与注意事项

1. **MAME 版本锁定**：项目已针对 MAME 0.288 修复兼容性。关键变更：
   - `emu.register_frame` → `emu.register_periodic`
   - `-autoboot_script`（macOS 不可用）→ `-plugin luafighter`
   - `manager.machine` 在 `startplugin` 中为 `nil`，需延迟到 Frame 3+ 初始化
   - MAME Lua 无 `luasocket`，通信降级到文件 I/O

2. **CPS1 输入注入限制**：
   - 玩家方向/拳脚（IN1，`0x800000-0x800007`）通过 read-tap 注入**有效**。
   - 投币/开始（IN0）在 attract 阶段无法通过 read-tap 注入游戏逻辑，因为游戏 VBLANK 在该阶段不检查 IN0。详见 `docs/cps1-input-limitation.md`。
   - `automation.lua` 中通过 `0x800030` 的 read-tap 尝试模拟投币计数器，但实际能否被游戏识别需要实测验证。

3. **内存地址待验证**：
   - `sf2ce.json` 中的 `stateAddress` 为 `null`，`automation.lua` 使用硬编码默认值 `0xFF8ABF`。
   - `sf2.json` 和 `kof97.json` 中的地址目前为占位值或社区参考值，**必须通过 MAME 调试器实际验证**。
   - 项目 Stage 9（内存地址实际对战验证）尚未完成。

4. **ROM 版权**：项目不附带任何 ROM。用户需自行准备合法 ROM 副本放入 `roms/`。

5. **插件路径硬编码**：`plugins/luafighter/init.lua` 第 10 行硬编码了绝对路径 `/Users/gavin/playground/gameplay/luafighter/lua-scripts`。在其它环境部署前必须修改。

6. **前端路由**：Nginx 和 Vite 均配置了 `try_files ... /index.html`，支持 React Router 的浏览器路由。

7. **服务启动顺序**：
   1. `market-data`（必须先于 match-manager 启动）
   2. `match-manager`
   3. `media-streamer`（创建房间后按需要调用 `/api/streams/:roomId/start`）
   4. `frontend`

8. **日志位置**：
   - Lua 脚本默认写入 `/tmp/luafighter-debug.log`。
   - 校准脚本写入 `/tmp/luafighter-calibration.log`。
   - LuaBridge 文件通信使用 `/tmp/luafighter_ipc_<roomId>_{in,out}`。

## 安全考虑

- ROM 文件被 `.gitignore` 忽略，不要提交任何受版权保护的内容。
- MAME 插件 `init.lua` 包含绝对路径，部署前请按实际环境修改。
- Docker Compose 中的 `match-manager` 使用 `privileged: true` 以运行 Xvfb 和 MAME，生产环境如需部署请评估容器安全风险。
- 当前后端 CORS 设置为 `origin: '*'`（`match-manager/src/index.ts`），生产部署应收紧为实际前端域名。
- 调试日志可能包含路径信息，发布前注意清理。

## 扩展开发路径

### 添加新 ROM

1. 创建 `lua-scripts/rom-configs/<rom>.json`。
2. 若硬件与 CPS1 不同，调整 `utils/input-controller.lua` 的 `PORT_CONFIG`。
3. 在 `automation.lua` 的默认配置或 `readGameState` 中添加该 ROM 的状态机逻辑（如需要）。
4. 用 `debugmemory` 插件或 `./scripts/calibrate.sh <rom>` 验证地址。
5. 更新前端 `RoomList.tsx` 的 ROM 名称映射。

### 接入真实行情

1. 在 `packages/market-data/src/data-source.ts` 中实现 `SinaDataSource` 或 `EastMoneyDataSource`。
2. 在 `packages/market-data/src/index.ts` 中替换/增强 `MockDataSource`。

### 添加新策略

1. 修改 `packages/match-manager/src/decision-engine.ts` 的 `decide()`。
2. 在 `lua-scripts/drivers/automation.lua` 中根据 `currentStrategy` 执行新的输入逻辑。

## 参考文档

- `README.md`：项目介绍和快速开始
- `docs/integration-guide.md`：完整集成指南、API 参考、故障排查
- `docs/mame-0.288-compatibility.md`：MAME 0.288 兼容性细节
- `docs/cps1-input-limitation.md`：CPS1 输入注入限制分析
- `docs/audit-report.md`：系统自检报告和待办清单
