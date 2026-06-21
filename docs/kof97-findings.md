# KOF97 (Neo Geo) 自动化对战调研笔记

> 测试环境：MAME 0.288 (macOS)，ROM `kof97.zip` + `neogeo.zip`
> 测试时间：2026-06-21
> 相关工具：`cheat0279.zip`（MAME 0.279 作弊码集）

## 关键结论

1. **KOF97 可以自动进入对战**：通过 Lua 端口注入 `Coin` + `Start` + `A`，可以在 MAME 启动后约 10~20 秒进入 1P vs CPU 的完整对战。
2. **CPS1 的 coin/start 限制在 Neo Geo 上不存在**：KOF97 的 `:AUDIO_COIN` 和 `:edge:joy:START` 端口可以正常被 `field:set_value()` 控制。
3. **当前稳定模式为 1P vs CPU**：多次尝试进入 2P 对战未成功；画面中出现两个角色，但 P2 行为更像 CPU，对 JOY2 方向键不响应。
4. **1P vs CPU 已可控制移动/攻击**：JOY1 控制 P1（左侧角色），P1 可前进、后退、出拳/脚/跳/重击。

## 已验证内存地址

| 含义 | 地址 | 类型 | 备注 |
|------|------|------|------|
| P1 当前角色血量 | `0x108239` | u8 | 满血 103 (0x67) |
| P2 当前角色血量 | `0x108439` | u8 | 满血 103 (0x67) |
| P1 X 坐标 | `0x108302` | u16 | 世界坐标，战斗初始约 24592 |
| P2 X 坐标 | `0x108502` | u16 | 世界坐标，战斗初始约 18156 |
| 对战时间 | `0x10A83A` | u8 | 96 开始递减；0 表示非对战/过渡 |

### 地址推导过程

- 血量地址来自 `cheat0279/kof97.xml`：
  - P1 Infinite Energy: `maincpu.pb@108239=67`
  - P2 Infinite Energy: `maincpu.pb@108439=67`
- 坐标地址通过“让 P1 持续向右移动，扫描 0x108000~0x108A00 区间 16 位值变化”得到。
  - 仅 P1 移动时，`0x108302` 大幅变化；`0x108502` 几乎不变。
  - 因此 `0x108302` 对应 P1，`0x108502` 对应 P2。

## 输入端口与字段

### 系统端口

| 端口 tag | 字段名 | mask | 作用 |
|----------|--------|------|------|
| `:AUDIO_COIN` | `Coin 1` | ? | 1P 投币 |
| `:AUDIO_COIN` | `Coin 2` | ? | 2P 投币 |
| `:edge:joy:START` | `1 Player Start` | 1 | 1P 开始 |
| `:edge:joy:START` | `2 Players Start` | 4 | 2P 开始 |

### 玩家控制端口

| 端口 tag | 字段名 | mask |
|----------|--------|------|
| `:edge:joy:JOY1` | `P1 Up` | 1 |
| `:edge:joy:JOY1` | `P1 Down` | 2 |
| `:edge:joy:JOY1` | `P1 Left` | 4 |
| `:edge:joy:JOY1` | `P1 Right` | 8 |
| `:edge:joy:JOY1` | `P1 A` | 16 |
| `:edge:joy:JOY1` | `P1 B` | 32 |
| `:edge:joy:JOY1` | `P1 C` | 64 |
| `:edge:joy:JOY1` | `P1 D` | 128 |
| `:edge:joy:JOY2` | `P2 Up` | 1 |
| `:edge:joy:JOY2` | `P2 Down` | 2 |
| `:edge:joy:JOY2` | `P2 Left` | 4 |
| `:edge:joy:JOY2` | `P2 Right` | 8 |
| `:edge:joy:JOY2` | `P2 A` | 16 |
| `:edge:joy:JOY2` | `P2 B` | 32 |
| `:edge:joy:JOY2` | `P2 C` | 64 |
| `:edge:joy:JOY2` | `P2 D` | 128 |

> 注：Neo Geo 端口使用 active-low，`field:set_value(1)` 会把对应 bit 拉低，游戏识别为按下。读取端口值可验证：`port:read()` 从 255 变为 `255 - mask`。

## 自动进入对战的最小按键序列

从 MAME 启动开始，持续约 10~20 秒执行以下脉冲即可进入 1P vs CPU 对战：

```lua
-- 每 30 帧一个周期
if cycle < 10 then coinField:set_value(1) else coinField:set_value(0) end
if cycle >= 10 and cycle < 15 then start1Field:set_value(1) else start1Field:set_value(0) end
if cycle >= 15 and cycle < 18 then p1A:set_value(1) else p1A:set_value(0) end
```

关键：
- 必须从启动早期（F~10）开始按键，错过 title screen 后会长期停留在 attract demo 循环。
- 仅按 `Start` 或仅按 `Coin` 不够；配合 `A` 可以帮助跳过模式/角色选择菜单。

## 对战中的方向逻辑

- P1 初始在左侧，面向右：
  - `P1 Right` = 前进（朝 P2）
  - `P1 Left` = 后退（远离 P2）
- P2 初始在右侧，面向左：
  - `P2 Left` = 前进（朝 P1）
  - `P2 Right` = 后退（远离 P1）

## 对战中的实战经验

1. **血量/时间锁定可用于练习**
   - 向 `0x108239` 写 `0x67`、向 `0x10A83A` 写 `0x60`，1P 血量和对战时间会保持满值。
   - 这适合在练习模式或对战阶段无限测试招式，但不要在菜单/选人阶段随意写入，以免干扰游戏流程。

2. **方向键和攻击键同时按会互相冲突**
   - 在移动中按攻击键，游戏往往只响应方向，表现为“完全不出招”。
   - 有效做法：先靠近，再松开方向键，然后短按 `C`/`D`；或者使用带位移的招式（如 236A）。

3. **坐标应解释为 signed 16-bit**
   - `0x108302` / `0x108502` 读取的 u16 值超过 `32767` 时，实际应视为负数（屏幕左侧）。
   - 用 `diff = p2x - p1x`（有符号）判断左右更可靠，避免 65535 环绕误判。

4. **普通攻击距离很短**
   - 站 `C` / `D` 只有在两人贴身（距离 < ~5000 内部单位，约 20 像素）时才命中。
   - 远距离只靠乱按无法打中 CPU，必须配合移动或飞行道具。

## 已集成的项目改动

- `lua-scripts/rom-configs/kof97.json`：更新为 KOF97 实测地址、Neo Geo 端口映射，并增加 `attackDistance` 等提示。
- `lua-scripts/utils/input-controller.lua`：新增 Neo Geo 路径，使用 `field:set_value` 注入；修复按键释放和方向映射，支持 `p1InputMap`/`p2InputMap` 的逻辑键名。
- `lua-scripts/drivers/automation.lua`：新增 Neo Geo 阶段检测（基于倒计时+血量）和早期进场序列；位置读取改为有符号；`attackDistance` 可配置。
- `scripts/test-lua.sh`：自动导出 `LUAFIGHTER_ROM`，测试指定 ROM 时无需手动设置环境变量。

### 验证结果

运行 `./scripts/test-lua.sh kof97` 可在 70 秒内自动进入 1P vs CPU 对战并赢下第一局：

```
[Automation] 阶段切换: fight
[Automation] F1200 Phase=fight state=0x60 P1HP=103 P2HP=103 P1X=-2972 P2X=18388
...
[Automation] Round 1 结束，胜者 P1 (1-0)
```

CPS1（SF2CE）路径未受影响，仍可正常进入对战。

## 待解决问题

1. **2P 对战模式**：目前只能稳定进入 1P vs CPU。尝试投双币 + 2P Start 仍进入 1P vs CPU。可能需要：
   - 使用 Universe BIOS (`-bios unibios40`) 的 VS 模式菜单；
   - 在 title screen 精确时机按 2P Start；
   - 或者接受 1P vs CPU 作为 betting 的对战形式。
2. **AI 策略**：当前仅实现“靠近 + 站桩按 ABCD”，需要更智能的防御、连段、距离控制，以及按角色区分的出招表。
3. **多角色/换角色**：KOF97 是 3v3，当前地址是“当前出战角色”血量，队伍其他角色血量在其他偏移，需要进一步标定。

## 文件位置

- ROM 配置：`lua-scripts/rom-configs/kof97.json`
- 驱动脚本：`lua-scripts/drivers/automation.lua`
- 输入控制：`lua-scripts/utils/input-controller.lua`
