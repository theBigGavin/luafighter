# LuaFighter - 数据驱动街霸/拳皇自动对战项目执行计划

## 项目概述
构建一个基于 MAME + Lua 脚本 + Node.js + React 的数据驱动街机格斗自动对战系统。行情数据驱动游戏内角色的攻防策略，通过 WebRTC 低延迟直播到前端。

---

## 阶段一：项目骨架与基础配置 (Stage 1) ✅ 已完成
- [x] Monorepo 目录结构（packages, lua-scripts, docker, scripts）
- [x] 根 package.json workspaces 配置
- [x] TypeScript 配置 (tsconfig.json)
- [x] 共享类型包 (@luafighter/shared-types)
- [x] ROM 配置文件模板 (sf2ce.json, kof97.json)
- [x] 前端工具链配置 (Vite, React)

---

## 阶段二：行情数据服务 (Stage 2) ✅ 已完成
- [x] MockDataGenerator - 模拟行情数据生成器（多种场景模式）
- [x] StrengthCalculator - 多空强度计算引擎（滑动窗口 + EMA 平滑）
- [x] DataSource 抽象接口（Mock / Sina / EastMoney 预留）
- [x] WebSocket + HTTP 服务入口
- [x] 动态 symbol 订阅支持

---

## 阶段三：对局管理器核心 (Stage 3) ✅ 已完成
- [x] MamePool / MameProcessManager - MAME 进程池管理
- [x] LuaBridge - WebSocket 双向通信桥
- [x] GameRoom - 房间生命周期与状态管理
- [x] DecisionEngine - 多空 → 攻防策略映射引擎
- [x] MarketDataClient - 行情数据连接客户端
- [x] HTTP API + Socket.IO 状态广播
- [x] 自动重启与健康检查

---

## 阶段四：MAME Lua 自动化脚本 (Stage 4) ✅ 已完成
- [x] memory-reader.lua - 内存读取封装（U8/U16/S16）
- [x] input-controller.lua - 输入控制器（按键、方向、连招）
- [x] json.lua - 轻量级 JSON 编解码器
- [x] websocket.lua - WebSocket 客户端 + 降级方案
- [x] automation.lua - 主驱动脚本（完整状态机）
- [x] boot.lua - MAME 启动脚本
- [x] 游戏状态机：标题 → 选人 → 对战 → 结算 → 循环
- [x] 跨 ROM 配置化支持

---

## 阶段五：媒体推流服务 (Stage 5) ✅ 已完成
- [x] FFmpegStreamer - FFmpeg 捕获与推流管理
- [x] StreamManager - 多房间流生命周期管理
- [x] macOS / Linux 平台适配（avfoundation / x11grab）
- [x] MediaMTX WebRTC 集成
- [x] HTTP API 控制接口

---

## 阶段六：React 前端 (Stage 6) ✅ 已完成
- [x] App.tsx - 主路由与布局
- [x] RoomList - 房间列表 / 创建弹窗
- [x] WatchRoom - 对战观看页面（视频 + 数据 + 日志）
- [x] VideoPlayer - WHEP WebRTC 播放器
- [x] ScoreBoard - 比分板与血量条
- [x] MarketPanel - 多空仪表盘
- [x] StrengthChart - ECharts 实时趋势图
- [x] EventLog - 事件日志
- [x] Socket.IO 连接管理
- [x] 完整 CSS 样式（暗色主题）

---

## 阶段七：Docker 化与部署 (Stage 7) ✅ 已完成
- [x] Dockerfile.base - 基础镜像（MAME + FFmpeg + Node.js）
- [x] Dockerfile.frontend - 前端构建 + Nginx
- [x] docker-compose.yml - 全服务编排
- [x] nginx.conf - 反向代理配置
- [x] mediamtx.yml - 媒体网关配置
- [x] start.sh - 一键启动脚本
- [x] README.md - 完整项目文档
- [x] .gitignore - 忽略配置

---

## 项目统计
- 文件总数: 50+
- 代码行数: ~3500+ (TypeScript + Lua + CSS)
- 服务数量: 5 (行情 + 管理器 + 媒体 + MediaMTX + 前端)
- 支持 ROM: 街霸2 (sf2ce), 拳皇97 (kof97)

## 执行顺序完成 ✅
所有阶段已按计划完成，项目可直接进入编译测试和部署阶段。
