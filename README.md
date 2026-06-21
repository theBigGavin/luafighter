# LuaFighter 🥊

数据驱动街霸/拳皇自动对战系统

基于 **MAME + Lua 脚本 + Node.js + React** 的完整技术方案，实现实时行情数据驱动街机格斗游戏的自动对战，通过 WebRTC 低延迟直播到浏览器。

---

## 系统架构

```
┌─────────────┐      行情数据        ┌─────────────────┐
│ 行情数据服务  │ ──WebSocket──────▶ │   对局管理器      │
│ (Node.js)   │                    │  (Node.js 核心)   │
└─────────────┘                     └──────┬──────────┘
                                           │
                              ┌─────────────┼─────────────┐
                              │ 启动/管理    │ 发送指令     │ 接收状态
                              ▼             ▼              ▼
                      ┌──────────────┐ ┌──────────┐ ┌───────────┐
                      │  MAME 实例池   │ │ Lua 桥接  │ │ 媒体推流服务│
                      │ (多进程)       │ │(WebSocket│ │ (FFmpeg/  │
                      │  + Lua 脚本   │ │ + File)  │ │  WebRTC)  │
                      └──────┬───────┘ └─────┬────┘ └─────┬─────┘
                             │                │            │
                             ▼                ▼            ▼
                      ┌──────────────────────────────────────────┐
                      │               React 前端                  │
                      │  观看画面 (WebRTC) | 数据展示 | 实时对战    │
                      └──────────────────────────────────────────┘
```

---

## 技术栈

| 组件 | 技术 | 说明 |
|------|------|------|
| 模拟器 | MAME 0.288 | 支持 Lua 插件、内存读写、输入注入 |
| 脚本 | Lua 5.3+ | 帧回调、状态机、输入控制 |
| 后端 | Node.js 18+ | 异步 I/O，进程管理，WebSocket |
| 前端 | React 18 + Vite | 组件化，响应式数据展示 |
| 推流 | FFmpeg + MediaMTX | RTMP 捕获转 WebRTC |
| 数据 | 模拟/新浪/东方财富 | 实时 Tick 数据，多空强度计算 |
| 可视化 | ECharts | 实时多空趋势图表 |

---

## ⚠️ MAME 0.288 兼容性说明（macOS）

本项目已针对 **MAME 0.288 (macOS ARM64)** 完成兼容性修复，关键变更如下：

| 问题 | 修复方案 | 文件 |
|------|---------|------|
| `-autoboot_script` 不支持 | 改用 `-pluginspath` + `-plugin` 加载 Lua 插件 | `mame-pool.ts` |
| `emu.register_frame` 已移除 | 改用 `emu.register_periodic` | `automation.lua` |
| `manager.machine` 在 `startplugin` 中为 `nil` | 延迟初始化：`spaces` 和 `ioport` 在 Frame 3+ 重新获取 | `memory-reader.lua`, `input-controller.lua` |
| Lua 无 `luasocket` | WebSocket 降级到文件 I/O (`/tmp/luafighter_ipc_*`) | `lua-bridge.ts`, `websocket.lua` |
| 输入端口 `__index` 行为异常 | 使用 CPS1 位掩码直接注入 `ioport:set_value()` | `input-controller.lua` |
| 启动提示屏 | `mame.ini` 中设置 `skip_gameinfo 1` | `roms/mame.ini` |

> 详细兼容性文档见 [docs/mame-0.288-compatibility.md](docs/mame-0.288-compatibility.md)

---

## 快速开始

### 环境要求

- macOS 15+ (开发推荐) 或 Linux
- Node.js 18+
- MAME 0.288 (`brew install mame`)
- FFmpeg (`brew install ffmpeg`)
- Docker & Docker Compose (可选，用于部署)

### 1. 克隆项目

```bash
git clone <repo-url>
cd luafighter
```

### 2. 安装依赖

```bash
npm install
npm run build
```

### 3. 准备 ROM 文件

将 ROM 文件放入 `roms/` 目录（如 `sf2ce.zip`、`kof97.zip`）：

```bash
mkdir -p roms
# 放入你自己的 ROM 文件（注意版权合规）
```

### 4. 配置 MAME

`roms/mame.ini` 已预配置：
- `rompath` 指向 `./roms`
- `pluginspath` 指向 `./plugins`
- `skip_gameinfo 1` 跳过启动提示

如需自定义，编辑 `roms/mame.ini`。

### 5. 启动服务（开发模式）

终端 1 - 行情数据服务：
```bash
npm run dev:market
```

终端 2 - 对局管理器：
```bash
npm run dev:manager
```

终端 3 - 前端：
```bash
npm run dev:frontend
```

终端 4 - 媒体推流（可选）：
```bash
npm run dev:media
```

### 6. 访问界面

打开浏览器访问 `http://localhost:3000`

---

## Docker 部署

### 一键启动

```bash
./scripts/start.sh
```

### 手动操作

```bash
cd docker
docker-compose up --build -d
```

访问 `http://localhost` 即可使用。

---

## 项目结构

```
luafighter/
├── packages/
│   ├── shared-types/      # 共享类型定义
│   ├── market-data/       # 行情数据服务
│   ├── match-manager/     # 对局管理器
│   ├── media-streamer/    # 媒体推流服务
│   └── frontend/          # React 前端
├── lua-scripts/
│   ├── drivers/           # Lua 主驱动脚本
│   ├── utils/             # Lua 工具模块
│   └── rom-configs/       # ROM 配置文件
├── plugins/
│   └── luafighter/        # MAME 插件入口
├── docker/                # Docker 配置
├── scripts/               # 启动脚本
├── package.json           # 根 workspaces 配置
└── tsconfig.json          # TypeScript 配置
```

---

## 核心功能

### 行情数据驱动

- 实时计算多空强度指数 `strengthIndex` (-1.0 ~ 1.0)
- 多方优势 → 1P 进攻，空方优势 → 2P 进攻
- 强制接近约束，防止双方无限远离

### 游戏自动化

- 完整的游戏状态机：标题 → 选人 → 对战 → 结算 → 循环
- 内存读取：血量、坐标、状态标志
- 输入注入：方向、拳脚、组合招式（波动拳、升龙拳等）
- 跨 ROM 适配：街霸2 (sf2ce)、拳皇97 (kof97)

### 低延迟直播

- FFmpeg 捕获 MAME 窗口
- RTMP 推流到 MediaMTX
- WebRTC 播放，延迟 < 2秒

### 数据可视化

- 实时多空强度趋势图
- 成交额对比
- 血量条、比分板
- 事件日志

---

## 关键配置

### ROM 配置 (`lua-scripts/rom-configs/*.json`)

每个 ROM 需要配置：

- `stateAddress` - 游戏状态内存地址
- `p1HealthAddr` / `p2HealthAddr` - 血量地址
- `p1XAddr` / `p2XAddr` - 坐标地址
- `p1InputMap` / `p2InputMap` - 输入端口映射（逻辑名 → MAME 字段名）
- `combos` - 招式组合定义

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ROMS_DIR` | `./roms` | ROM 文件目录 |
| `LUA_SCRIPT_PATH` | `lua-scripts/drivers/automation.lua` | Lua 驱动脚本路径 |
| `DISPLAY` | `:99` | Xvfb 显示编号 |
| `MEDIA_MTX_URL` | `rtmp://localhost:1935/live` | RTMP 推流地址 |

---

## 开发路线图

- [x] **Stage 1**: 项目骨架与基础配置
- [x] **Stage 2**: 行情数据服务（模拟 + 计算引擎）
- [x] **Stage 3**: 对局管理器核心（房间 + 决策引擎）
- [x] **Stage 4**: MAME Lua 自动化脚本
- [x] **Stage 5**: 媒体推流服务（FFmpeg + WebRTC）
- [x] **Stage 6**: React 前端（观看 + 数据 + 交互）
- [x] **Stage 7**: Docker 化与部署
- [x] **Stage 8**: MAME 0.288 兼容性修复
- [ ] **Stage 9**: 内存地址实际对战验证（需要进入游戏对战确认 HP 地址）

---

## 注意事项

### ROM 版权

本项目仅提供技术框架，不附带任何 ROM 文件。用户需自行准备合法的 ROM 副本。

### 行情数据

当前使用模拟数据生成器。如需接入真实行情，请：
1. 实现 `SinaDataSource` 或 `EastMoneyDataSource`
2. 配置合法的行情数据订阅

### 性能

- 单台服务器可运行 8+ 个 MAME 实例（无渲染时 CPU 占用极低）
- 每个实例推荐分配 1GB 内存

---

## 技术文档

- [MAME Lua 参考](https://docs.mamedev.org/debugger/luaengine.html)
- [MediaMTX 文档](https://github.com/bluenviron/mediamtx)
- [FFmpeg x11grab](https://ffmpeg.org/ffmpeg-devices.html#x11grab)
- [MAME 0.288 兼容性指南](docs/mame-0.288-compatibility.md)
- [集成指南](docs/integration-guide.md)

---

## License

MIT License

Copyright (c) 2024 LuaFighter Project

---

**Made with 🥊 by LuaFighter Team**
