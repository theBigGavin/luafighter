# LuaFighter 重设计实施计划

> 2026-07-27 制定。基于对控制链路（Node 决策 → 通信桥 → Lua 状态机 → 输入注入）的完整审查。
> 审查结论：项目分层方向合理，但通信、输入注入、地址管理三个关键选型脆弱，且 fail-open 哲学掩盖了所有故障。

## 实施状态（2026-07-28 更新）

**Phase 1 已完成并通过 MAME 实测**（`mame kof97 -plugin luafighter`，stock BIOS，240 秒）：

- 投币 → Start → 选人 → 真实对战 → KO → 回合切换 → 计分全链路打通；
- 血量/坐标遥测实时变化，round_end 按 FIGHT→KO 阶段切换正确触发，比分交替上升；
- TS 全量构建通过，Lua 5.3 语法检查通过，LuaBridge 文件模式冒烟测试 7/7 通过。

实测中新发现并修复的关键问题（原根因清单之外）：

| # | 问题 | 修复 |
|---|------|------|
| R8 | **插件从未启动**：MAME 0.288 通过 pluginspath 下的 `boot.lua` 启动插件，自定义 `-pluginspath` 后该文件缺失，`-plugin` 静默无效 | 新增 `plugins/boot.lua` |
| R9 | kof97.json 地址全错（HP 偏移 +1、X 坐标无中生有、state/hit/facing 虚构） | 换成 cheat DB + 实测地址，删除虚构地址；`p2XAddr` 经内存 diff 探针校正为 `0x108422` |
| R10 | NeoGeo read-tap 与 field:set_value 双轨注入互相抵消（装 tap 后投币都失败）；START tap 对 BIOS 字节读（mask=0xFF00）静默失效 | NeoGeo 改 `field:set_value` 单轨（tap 保留但默认关闭，`LUAFIGHTER_TAP=1` 启用） |
| R11 | `field:set_value` 效果只维持一帧，InputController 的"设一次 hold N 帧"模型失效 | `updateFrame` 中每帧重注所有 active 输入 |
| R12 | BIOS 只在标题/attract 特定窗口接收投币/Start，稀疏脉冲必错过 | `entry-kof97.lua` 改 30 帧周期持续脉冲（June 文档时序） |
| R13 | unibios40 启动画面被持续按键触发内置作弊菜单（A+B+C） | 改用 stock BIOS（`kof97.json` 移除 `bios`，`test-lua.sh` 同步） |
| R14 | 阶段检测在战斗期间被 state=0 误导，FIGHT/ATTRACT 高频抖动 | NeoGeo 检测器切 ATTRACT 要求无血无计时 |
| R15 | KOF97 KO 后队友立即上场，血量读不到 0，round_end 永不触发 | 以 FIGHT→KO/WIN 阶段切换作为回合结束信号，胜者按剩余血量判定 |

遗留（不阻塞主链路）：P2 X 坐标（0x108422）在 VS 模式下读数噪声大，距离类决策精度有限；SF2/CPS1 仍未验证（Phase 3 处理）。

---

## 已确认的根因清单

| # | 根因 | 位置 | 影响 |
|---|------|------|------|
| R1 | KOF97 距离量纲错误：`dist=rawDist/64`（像素 0~320 → 0~5）对比硬编码 `attackDist=120`，永远判定为近战 | `ftg-ai-arena.lua:373-375, 455-457` | 策略执行层名存实亡，行情退化为"攻击/后退"两态开关 |
| R2 | 血量三处三种位宽：automation 用 U8（对）、phase-detectors 用 U16+clamp（恒为满血）、ftg-ai 用 S16（阈值失效）；memory-reader 降级路径按小端拼接（68k 是大端） | `phase-detectors.lua:30-38`、`ftg-ai-arena.lua:85-88`、`memory-reader.lua:52-71` | 阶段检测血量判据全失效，KO/SELECT 靠运气 |
| R3 | `isControllable` 每帧 `releaseAll()`，地址偏差时角色永久木桩化且外部输入也被清空 | `ftg-ai-arena.lua:693-699` | "角色完全不受控"的最直接嫌疑 |
| R4 | NeoGeo COIN mask 与方向键共用 tap 状态字节，投币=幽灵方向键 | `input-controller.lua:124-127, 285` | 进场/投币污染战斗输入 |
| R5 | 策略 TTL 60 帧（1s）+ 文件 IPC 读后截断竞态丢命令，策略通道间歇性失效 | `ftg-ai-arena.lua:28`、`websocket.lua:150-151`、`lua-bridge.ts:183` | 行情驱动时断时续，无任何报错 |
| R6 | CPS1 投币/Start 无法注入（IN0 硬件级限制），SF2 永远无法开局；combo 对 CPS1 硬禁用 | `docs/cps1-input-limitation.md`、`input-controller.lua:931` | SF2 路径整体不可用 |
| R7 | 双端各一套状态机（Node 记 score、Lua 记 p1Wins），fail-open 兜底掩盖故障 | `game-room.ts`、`automation.lua` | 故障不可见，调试靠猜 |

## 重设计原则

1. **Fail-fast，拒绝静默兜底**：地址未验证不进 FIGHT；通信失败要可见；删掉"返回默认值继续跑"式的降级。
2. **状态机单端化**：Lua 只做帧级执行 + 遥测上报；房间状态（回合、比分、策略）只由 Node 持有。
3. **先垂直打通单 ROM（KOF97），再横向扩展**：CPS1/SF2 在系统键注入方案落地前标记为不可用。
4. **最小可行通信**：协议带 seq/ack + 重发，消灭 TTL 猜测式过期。

## 阶段划分

### Phase 1：控制链路地基修复（本次实施）

目标：不动架构，把 R1~R5 修掉，让 KOF97 的角色行为真正受策略驱动。

| 步骤 | 文件 | 内容 |
|------|------|------|
| 1.1 | `lua-scripts/utils/memory-reader.lua` | readU16 降级路径改大端拼接（`lo*256+hi`）；readU32 改大端（`lo*65536+hi`） |
| 1.2 | `lua-scripts/utils/phase-detectors.lua`、`lua-scripts/drivers/ftg-ai-arena.lua` | 血量统一 readU8 |
| 1.3 | `lua-scripts/drivers/ftg-ai-arena.lua` | 距离用像素 rawDist，attackDist 用 `config.attackDistance`；`_readX` 读失败返回 nil 并显式置 xReliable=false，删除 80/240 默认值与魔法哨兵 |
| 1.4 | `lua-scripts/drivers/ftg-ai-arena.lua` | 不可控时不再每帧 releaseAll：仅在"可控→不可控"跳变时松一次键 |
| 1.5 | `lua-scripts/utils/input-controller.lua` | COIN 不进入 NeoGeo tap 状态字节（只走 field:set_value 路径） |
| 1.6 | `ftg-ai-arena.lua` + `lua-bridge.ts` + `automation.lua` + `shared-types` | 策略命令带 `seq`，Lua 回 `ack`，Node 500ms 未收到 ack 重发（最多 3 次）；TTL 60 → 600 帧作为兜底 |
| 1.7 | `lua-scripts/utils/websocket.lua`、`packages/match-manager/src/lua-bridge.ts` | 文件 IPC 改 append-only + 读取偏移量（Lua 记 offset seek 增量读；Node 用 fs.read position），消除读后截断竞态 |

验证：`npm run build` 通过；`luac -p` 语法检查全部改动的 Lua 文件；逐条对照根因清单确认修复。

### Phase 2：通信主通道调换 + 状态机单端化

- Lua → Node 主通道改为 stdout（MAME 是 Node 子进程，`mame-pool.ts` 捕获 stdout 按行解析 `LUA_EVENT:`），文件通道降级为备份。
- Lua 删除 p1Wins/gameEnded 计数，KO 事件上报后由 Node 统一计数；`game-room.ts` 成为唯一房间状态源。
- 验证：创建 KOF97 房间，前端比分/回合与 MAME 实际画面一致。

### Phase 3：系统键 OS 级注入（解 CPS1 死结）

- Docker 内用 `xdotool key` 向 Xvfb 中的 MAME 窗口发送投币/Start 键（走 MAME 正常输入路径，attract 阶段有效）；macOS 用 CGEvent。
- read-tap 仅保留战斗中的方向/拳脚注入。
- 完成后 SF2CE 重新标记为可用，移除 `handleAttract` 的 0x800030 实验性投币计数器。
- 验证：SF2CE 房间能从 attract 自动进入对战。

### Phase 4：校准门禁 + fail-fast

- 把 `research/cheat-db/` + `calibrate.sh` 串成正式校准流程：启动扫描 → 已知状态比对 → 生成/验证 rom-config。
- 未通过校准的 ROM 拒绝进入 FIGHT，前端房间卡片显示"未校准"状态。
- 验证：故意改错一个地址，系统明确报错而非静默演假戏。

### Phase 5：服务收敛 + 推流简化

- `market-data` 并入 `match-manager` 为内部模块（进程内事件总线替代 WebSocket 9001），单机部署只留 manager + streamer。
- FFmpeg 改 WHIP 直推 MediaMTX，省掉 RTMP 一跳；移除 `privileged: true`。
- 前端房间卡片增加校准状态与通信健康指示。

## 不在本次范围内

- 接入真实行情数据源（SinaDataSource/EastMoneyDataSource 仍为预留）。
- 更换模拟器底座（评估过 BizHawk/RetroArch，结论：留在 MAME，换输入法）。
- Docker 部署结构调整（Phase 3/5 涉及部分除外）。
