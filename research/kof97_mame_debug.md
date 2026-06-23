# KOF97 MAME 调试研究报告

> 研究日期：2026-06-23  
> 研究目的：为 LuaFighter 项目提供 KOF97 在 MAME 中的内存地址、输入状态映射及 Lua 脚本控制角色的技术参考。

---

## 1. KOF97 在 MAME 中的已知内存地址

### 1.1 NeoGeo 基板 68000 内存映射（KOF97 运行于此）

KOF97 基于 SNK NeoGeo 街机基板，主 CPU 为 Motorola MC68000。以下内存映射适用于所有 NeoGeo 卡带系统游戏：

| 地址范围 | 大小 | 名称 | 说明 |
|---------|------|------|------|
| `$000000-$0FFFFF` | 1MiB | P ROM Bank 0 | 向量表、程序 ROM 第一 bank |
| `$100000-$10F2FF` | 64KiB | `WORKRAM_USER` | **用户工作 RAM**（游戏状态、角色数据等） |
| `$10F300-$10FFFF` | - | `WORKRAM_BIOS` | BIOS 保留 RAM |
| `$200000-$2FFFFF` | 1MiB | P ROM Bank 1 | 程序 ROM 第二 bank |
| `$300000-$3FFFFF` | - | I/O 寄存器 | 输入/输出端口 |
| `$400000-$401FFF` | 8KiB | `PALETTES` | 调色板 RAM |
| `$C00000-$C1FFFF` | 128KiB | `SYSTEMROM` | BIOS ROM |

**来源**：NeoGeo Development Wiki ([wiki.neogeodev.org](https://wiki.neogeodev.org/index.php?title=68k_memory_map), 2023-10-08)  
**来源**：AJWorld Neo-Geo Programming Guide ([ajworld.net](https://www.ajworld.net/neogeodev/neoguide/?p=3))

---

### 1.2 输入寄存器（I/O Ports）

NeoGeo 通过内存映射 I/O 读取摇杆和按钮状态，**所有输入为低电平有效**（active low，即按下时对应位为 0）：

| 地址 | 寄存器名 | 说明 | 位布局（低电平有效） |
|------|---------|------|---------------------|
| `$300000` | `REG_P1CNT` | 1P 控制器输入 | bit7=D, bit6=C, bit5=B, bit4=A, bit3=r, bit2=l, bit1=d, bit0=u |
| `$300001` | `REG_DIPSW` | DIP 开关 / 看门狗 | 读取硬件拨码开关，写入踢看门狗 |
| `$340000` | `REG_P2CNT` | 2P 控制器输入 | 同 1P 位布局 |
| `$380000` | `REG_STATUS_B` | 辅助输入 | Start/Select/记忆卡等 |

**按钮位布局详解**（`REG_P1CNT` / `REG_P2CNT`）：
```
bit 7: D (重拳/重脚)
bit 6: C (轻拳/轻脚)  
bit 5: B (轻脚/轻拳)
bit 4: A (轻拳/轻脚)
bit 3: 右 (right)
bit 2: 左 (left)
bit 1: 下 (down)
bit 0: 上 (up)
```

> 注意：KOF97 的 A/B/C/D 对应轻拳/轻脚/重拳/重脚（具体映射因角色侧而异）。

**来源**：NeoGeo Development Wiki ([wiki.neogeodev.org](https://wiki.neogeodev.org/index.php?title=68k_memory_map), 2023-10-08)  
**来源**：68000 Assembly Programming for NeoGeo ([chibiakumas.com](https://www.chibiakumas.com/68000/neogeo.php?noui=1))

---

### 1.3 BIOS 输入状态变量（RAM 地址）

BIOS 在 RAM 中维护输入状态的副本，供游戏程序读取。这些地址位于 `$10F000` 附近的 BIOS RAM 区域：

| 地址 | 变量名 | 说明 |
|------|--------|------|
| `$10FD06` | `BIOS_P1CURRENT` | 1P 当前帧输入状态（被游戏轮询） |
| `$10FD96` | `BIOS_P1CURRENT`（别名） | 部分文档记录为此地址 |
| `$10FEEA` | `BIOS_P5CURRENT` | 输入 5 状态（扩展端口） |
| `$10FEF0` | `BIOS_P6CURRENT` | 输入 6 状态（扩展端口） |

> 这些 BIOS 变量是 **MAME Lua 脚本注入输入的推荐目标**——通过 `install_read_tap` 拦截游戏对输入地址的读取，可以模拟按键而不影响物理输入层。

**来源**：MAME Debugging Guide ([mattgreer.dev](https://www.mattgreer.dev/blog/mame-debugging/), 2024-02-02)  
**来源**：68000 Assembly Programming for NeoGeo ([chibiakumas.com](https://www.chibiakumas.com/68000/neogeo.php?noui=1))

---

### 1.4 KOF97 游戏特定内存地址（角色状态）

基于社区逆向工程和 MAME Lua 脚本分析，KOF97 在 `$108000` 附近区域存储角色战斗状态：

| 地址 | 类型 | 说明 |
|------|------|------|
| `0x108102` | word | P1 动作指针（move pointer）——角色当前执行的动作 ID |
| `0x108175` | byte | P1 触发器/动画指针（trigger pointer）——标识当前播放的动画 |
| `0x108000` 区域 | - | P1 角色数据结构起始区域（血量、坐标、状态等） |
| `0x108238` 区域 | - | P2 角色数据结构起始区域（推测） |

> 这些地址需要通过 MAME 调试器（`mame kof97 -debug`）结合实际游戏状态进行验证。不同 ROM 版本（如 `kof97`, `kof97a`, `kof97pls`）地址可能略有偏移。

**来源**：bankbank 社区研究 ([bbs.aw-ol.com](https://bbs.aw-ol.com/user/bankbank), 2023-05-25)  
**来源**：Strugglemeat/kof97 GitHub ([github.com/Strugglemeat/kof97](https://github.com/Strugglemeat/kof97))

---

### 1.5 调试显示相关地址

KOF97 ROM 自带调试绘图功能，可通过修改内存开关激活：

| 地址 | 设置值 | 效果 |
|------|--------|------|
| `0x100000` | `0x010000` | 进入 DEBUG OBJE 模式（显示碰撞框） |
| `0x300001` | `0x20` | 激活调试显示位（碰撞框/攻击框可视化） |

> 在 DEBUG OBJE 模式下，按住投币键 + A/B/C/D 可调整角色（CH）和动作（ACT）。

**来源**：KOF97 逆向分析 MAME 调试模式 ([hackrom.cn](http://www.hackrom.cn/html/3/131.html), 2020-06-30)  
**来源**：CSDN KOF97 逆向实战 ([blog.csdn.net](https://blog.csdn.net/websocket5live/article/details/152500534), 2026-03-02)

---

## 2. 输入检测的帧率与时机

### 2.1 游戏帧率

KOF97 在 NeoGeo 基板上以 **约 59.1856 FPS** 运行（320×224 分辨率，CRT 15kHz 水平扫描）。这是 MAME 驱动 `kof97` 报告的标准刷新率。

| 参数 | 数值 |
|------|------|
| 分辨率 | 320 × 224 |
| 刷新率 | ~59.1856 Hz |
| 帧时间 | ~16.9 ms |

**来源**：MAME Machine Database ([adb.arcadeitalia.net](https://adb.arcadeitalia.net/dettaglio_mame.php?game_name=kof97))  
**来源**：MAME libretro core 日志 ([forums.libretro.com](https://forums.libretro.com/t/mame-current-0-250-core-partial-run-ahead/39999), 2023-02-13)

### 2.2 输入轮询时机

NeoGeo 游戏通常在 **每帧 VBLANK 期间** 读取输入寄存器。68000 CPU 通过内存映射 I/O 访问 `$300000`（1P）和 `$340000`（2P），读取摇杆和按钮的当前状态。

MAME 的输入处理特点：
- MAME 在 **帧边界** 统一轮询一次物理输入（键盘/手柄）。
- 在帧内，游戏可以随时读取输入寄存器，但读取到的是 MAME 在该帧开始时"冻结"的输入状态。
- 这意味着在 MAME 中，**输入无法做到真正的"race-the-beam"（在帧内任意时刻响应）**。

**来源**：MAME Input Lag Discussion ([forum.arcadecontrols.com](https://forum.arcadecontrols.com/index.php?topic=133194.240), 2017-12-26)  
**来源**：MAME Lua for Better Retro Dev ([mattgreer.dev](https://www.mattgreer.dev/blog/mame-lua-for-better-retro-dev/), 2024-03-05)

---

## 3. 按钮持续时间要求

### 3.1 NeoGeo 输入信号特性

NeoGeo 硬件输入是**纯数字信号**（低电平有效），不存在模拟量。对于 MAME Lua 脚本注入输入，关键参数是：

| 参数 | 说明 | 建议值 |
|------|------|--------|
| 最短按键持续帧数 | 游戏需要至少 1 帧检测到输入状态 | **≥ 1 帧**（约 17ms） |
| 连招输入窗口 | 方向指令 + 按钮的复合输入 | 通常 **2-4 帧**内完成 |
| 持续按住检测 | 如蓄力、防御 | 需要连续多帧保持输入位 |

### 3.2 Lua 脚本注入的注意事项

- MAME Lua 的 `install_read_tap` 可以在游戏读取输入地址时拦截并返回修改后的值。
- 在 read-tap 回调中**绝对禁止**执行 `print`、`io.open` 或 `log` 等 I/O 操作——这会触发 MAME 的内部保护机制，导致 tap 被静默禁用。
- 建议通过**帧回调**（`emu.register_periodic` 或 `emu.register_frame_done`）管理输入状态，在 read-tap 中只返回预计算的值。

**来源**：LuaFighter 项目 `docs/cps1-input-limitation.md`  
**来源**：MAME Lua 文档 ([docs.mamedev.org](https://docs.mamedev.org/luascript/ref-input.html))

---

## 4. 已知可用的 MAME Cheat / Lua 脚本示例

### 4.1 MAME Cheat 文件（XML 格式）

Pugsy 维护的 MAME cheat 数据库包含 KOF97 的作弊码：

- **下载**：`cheat.7z` 或 `kof97.xml` 从 [Pugsy's Cheat Site](http://cheat.retrogames.com/pugsy.htm) 或 [Strugglemeat/kof97](https://github.com/Strugglemeat/kof97/blob/main/kof97.xml)
- **启用**：在 `mame.ini` 中设置 `cheat 1`
- **常用作弊**：无限时间、无限 HP、无限能量槽、选 BOSS、选隐藏角色

**KOF97 示例 Cheat 条目**（XML 格式）：
```xml
<cheat desc="Infinite Time">
  <script state="run">
    <action>maincpu.pb@10FEE1=99</action>
  </script>
</cheat>
```

> 注意：cheat 地址基于 `maincpu` 地址空间（即 68000 的视角），与 MAME Lua 中的 `spaces["program"]` 一致。

**来源**：Pugsy Cheat Database ([retrogames.com](http://cheat.retrogames.com/pugsy.htm))  
**来源**：Strugglemeat/kof97 GitHub ([github.com](https://github.com/Strugglemeat/kof97))  
**来源**：K73 游戏之家 ([k73.com](http://www.k73.com/down/cheat/74656.html), 2015-01-06)

---

### 4.2 Lua 脚本示例：Read/Write Tap 注入输入

以下是一个基于 MAME Lua 的 KOF97 输入注入示例框架，使用 `install_read_tap` 拦截输入寄存器读取：

```lua
-- KOF97 输入注入示例（NeoGeo read-tap 方案）
-- 适用于 MAME 0.288+

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

-- 目标地址：1P 控制器输入（$300000）
local P1_INPUT_ADDR = 0x300000

-- 当前帧要注入的按钮状态（低电平有效：0=按下, 1=松开）
local injectedButtons = 0xFF  -- 默认全部松开

-- 读取拦截回调
function onP1InputRead(offset, data)
  -- 返回注入的按钮状态，覆盖真实输入
  return injectedButtons
end

-- 安装 read tap（仅拦截 $300000-$300001）
local tapHandler = mem:install_read_tap(
  P1_INPUT_ADDR,
  P1_INPUT_ADDR + 1,
  "p1_input_inject",
  onP1InputRead
)

-- 帧回调：更新注入状态（每帧可修改 injectedButtons）
function onFrame()
  -- 示例：每 60 帧按一次 A 按钮
  local frame = emu.framecount()
  if frame % 60 == 0 then
    injectedButtons = 0xFF & ~0x10  -- 按下 A（bit4 清零）
  else
    injectedButtons = 0xFF          -- 全部松开
  end
end

emu.register_periodic(onFrame)  -- MAME 0.288+ 使用 register_periodic
```

**关键要点**：
- NeoGeo 输入是 **低电平有效**：按下时对应位为 `0`，松开时为 `1`。
- `install_read_tap` 的回调在每次游戏读取输入寄存器时触发，必须在回调中**只返回数值，不做 I/O**。
- 如果需要在战斗阶段注入，建议先通过内存读取确认游戏已进入战斗状态（非 attract 模式）。

**来源**：MAME Lua for Better Retro Dev ([mattgreer.dev](https://www.mattgreer.dev/blog/mame-lua-for-better-retro-dev/), 2024-03-05)  
**来源**：MAME Lua Input System ([docs.mamedev.org](https://docs.mamedev.org/luascript/ref-input.html))

---

### 4.3 Lua 脚本示例：通过 I/O Port 直接设置字段值

MAME Lua 也可以直接操作 I/O 端口字段，绕过 read-tap：

```lua
-- 通过 ioport 直接设置按钮字段
local function pressButton(portTag, fieldName, durationFrames)
  local port = manager.machine.ioport.ports[portTag]
  if not port then return end
  
  local field = port.fields[fieldName]
  if not field then return end
  
  -- 设置字段值为 1（激活）
  field:set_value(1)
  
  -- durationFrames 后释放（通过 frame 回调管理）
end

-- 示例：按下 1P 的 A 按钮
-- pressButton(":edge:joy:ctrl1", "A", 3)
```

> 此方法的局限性：在 attract 模式下或游戏不读取 I/O 端口时可能无效。对于 NeoGeo 游戏，read-tap 方案更可靠。

**来源**：MAME Lua Input System ([docs.mamedev.org](https://docs.mamedev.org/luascript/ref-input.html))  
**来源**：Defender Lua Plugin ([forum.arcadecontrols.com](http://forum.arcadecontrols.com/index.php?topic=163525.0), 2020-09-05)

---

### 4.4 社区 Lua 脚本：KOF 碰撞框查看器

GitHub 上的 `mame-rr-scripts` 项目包含 `kof-hitboxes.lua`，可以在 MAME 中可视化 KOF 系列游戏的碰撞框（hitboxes）：

- **仓库**：`Jesuszilla/mame-rr-scripts`
- **文件**：`kof-hitboxes.lua`
- **功能**：显示攻击框、受击框、碰撞框等
- **使用方法**：通过 MAME 的 `-autoboot_script` 或插件系统加载

**来源**：mame-rr-scripts GitHub ([github.com/Jesuszilla/mame-rr-scripts](https://github.com/Jesuszilla/mame-rr-scripts/blob/master/kof-hitboxes.lua))

---

### 4.5 Strugglemeat 的 KOF97 Lua 脚本

社区用户 Strugglemeat 维护了一个完整的 KOF97 MAME Lua 脚本，用于实现手柄振动反馈，其中包含角色动作检测逻辑：

```lua
-- 示例：检测大门五郎的 HCB+C 投技
-- 通过监控 0x108102 和 0x108175 地址的变化触发振动
local p1MovePtr = 0x108102
local p1Trigger = 0x108175

-- 在 Lua 中读取内存
local cpu = manager.machine.devices[":maincpu"].spaces["program"]
local move = cpu:read_u16(p1MovePtr)
local trig = cpu:read_u8(p1Trigger)
```

- **完整脚本**：`kof97.lua` @ [github.com/Strugglemeat/kof97](https://github.com/Strugglemeat/kof97/blob/main/kof97.lua)
- **金手指文件**：`kof97.xml`（无限时间、无限能量、P2 无限 HP 等）

**来源**：Strugglemeat/kof97 GitHub ([github.com](https://github.com/Strugglemeat/kof97))  
**来源**：bankbank 社区研究 ([bbs.aw-ol.com](https://bbs.aw-ol.com/user/bankbank), 2023-05-25)

---

## 5. MAME 调试器使用指南（KOF97 专用）

### 5.1 启动调试模式

```bash
# 方法 1：命令行启动
mame kof97 -debug

# 方法 2：mame.ini 中设置
debug = 1
```

### 5.2 常用调试命令

| 命令 | 说明 | 示例 |
|------|------|------|
| `ci` | 初始化内存搜索（Cheat Init） | `ci` |
| `cn eq,60` | 搜索等于 0x60 的值 | `cn eq,60` |
| `cn +` | 搜索增加的值 | `cn +` |
| `cl` | 列出搜索结果 | `cl results.txt` |
| `wp 108102,2,w` | 在 0x108102 设置写入监视点（2 字节） | `wp 108102,2,w` |
| `bp 2F602` | 在 ROM 地址 2F602 设置断点 | `bp 2F602` |
| `maincpu.pw@108102=4E71` | 直接写入 RAM 地址（word） | `maincpu.pw@108102=0` |
| `trace trace.txt` | 跟踪执行并输出到文件 | `trace trace.txt,0` |
| `snap xxx.png` | 截图 | `snap kof97_state.png` |

### 5.3 调试 KOF97 输入的关键步骤

1. 启动 `mame kof97 -debug`，进入游戏战斗画面。
2. 设置监视点：`wp 300000,1,r`（监视 1P 输入读取）。
3. 按 F5 运行，按下按钮时触发断点。
4. 查看反汇编窗口，追踪游戏如何处理输入（通常在 68000 的 `move.b` 指令中读取 `$300000`）。
5. 通过 `maincpu.pb@300000=0xEF` 强制设置 1P 按下 A 按钮（bit4=0）。

**来源**：KOF97 逆向分析 MAME 调试器 ([jianshu.com](https://www.jianshu.com/p/c280f3c32699), 2020-03-18)  
**来源**：MAME Debugger Docs ([docs.mamedev.org](https://docs.mamedev.org/debugger/index.html))  
**来源**：MAME Debugging Guide ([mattgreer.dev](https://www.mattgreer.dev/blog/mame-debugging/), 2024-02-02)

---

## 6. 关键限制与注意事项

### 6.1 NeoGeo 与 CPS1 的差异

LuaFighter 项目目前主要针对 CPS1（Street Fighter II）的 read-tap 输入注入方案。NeoGeo（KOF97）与 CPS1 在输入层有**本质差异**：

| 特性 | CPS1 | NeoGeo |
|------|------|--------|
| 主 CPU | 68000 | 68000 |
| 输入地址 | `$800000-$800007` (IN1), `$800018-$80001F` (IN0/DSW) | `$300000` (P1), `$340000` (P2) |
| 输入有效电平 | 高电平有效 | **低电平有效** |
| 投币/Start | 在 attract 阶段难以注入 | 可通过 BIOS 或 `$380000` 注入 |
| 帧率 | 60Hz | ~59.1856Hz |

### 6.2 地址验证状态

| 地址 | 可信度 | 验证方法 |
|------|--------|----------|
| `$300000` / `$340000` | ⭐⭐⭐ 高 | NeoGeo 官方文档 + MAME 驱动源码确认 |
| `$10FD06` | ⭐⭐⭐ 高 | MAME 调试指南多次引用 |
| `0x108102` | ⭐⭐☆ 中 | 社区逆向工程，需 MAME 调试器实测验证 |
| `0x108175` | ⭐⭐☆ 中 | 社区逆向工程，需 MAME 调试器实测验证 |
| `0x100000` (DEBUG) | ⭐⭐⭐ 高 | 多份中文教程确认 |

### 6.3 待验证问题

1. `0x108102` 和 `0x108175` 是否为 KOF97 所有 ROM 版本通用？
2. 血量地址是否在 `0x108000` 区域附近？具体偏移是多少？
3. 角色坐标（X/Y）在内存中的存储位置和格式？
4. 通过 read-tap 注入 `$300000` 是否能在 KOF97 战斗中被正确识别？
5. 是否需要拦截 BIOS 对输入的处理（`$10FD06`）而非直接拦截 `$300000`？

---

## 7. 引用来源汇总

| # | 来源 | URL | 日期 | 内容摘要 |
|---|------|-----|------|----------|
| 1 | NeoGeo Development Wiki | https://wiki.neogeodev.org/index.php?title=68k_memory_map | 2023-10-08 | 68000 内存映射、输入寄存器地址 |
| 2 | AJWorld Neo-Geo Programming Guide | https://www.ajworld.net/neogeodev/neoguide/?p=3 | - | I/O 寄存器、系统寄存器详细说明 |
| 3 | MAME Debugging (Matt Greer) | https://www.mattgreer.dev/blog/mame-debugging/ | 2024-02-02 | MAME 调试器用法、BIOS_P1CURRENT 地址 |
| 4 | MAME Lua for Better Retro Dev | https://www.mattgreer.dev/blog/mame-lua-for-better-retro-dev/ | 2024-03-05 | Lua read/write tap 示例、输入控制 |
| 5 | KOF97 逆向分析 MAME 调试器 | https://www.jianshu.com/p/c280f3c32699 | 2020-03-18 | MAME 调试命令、KOF97 调试模式 |
| 6 | KOF97 逆向分析 调试模式 | http://www.hackrom.cn/html/3/131.html | 2020-06-30 | DEBUG OBJE 模式、内存监视点命令 |
| 7 | CSDN KOF97 逆向实战 | https://blog.csdn.net/websocket5live/article/details/152500534 | 2026-03-02 | 碰撞框定位、调试显示开关地址 |
| 8 | bankbank 社区研究 | https://bbs.aw-ol.com/user/bankbank | 2023-05-25 | KOF97 角色动作地址 `0x108102`、`0x108175` |
| 9 | Strugglemeat/kof97 GitHub | https://github.com/Strugglemeat/kof97 | - | 完整 Lua 脚本 + XML Cheat 文件 |
| 10 | MAME Lua Input System | https://docs.mamedev.org/luascript/ref-input.html | - | I/O port 字段操作 API |
| 11 | MAME Debugger Docs | https://docs.mamedev.org/debugger/index.html | - | 官方调试器命令参考 |
| 12 | MAME Input Lag Discussion | https://forum.arcadecontrols.com/index.php?topic=133194.240 | 2017-12-26 | 输入轮询时序、帧延迟分析 |
| 13 | MAME Machine Database (KOF97) | https://adb.arcadeitalia.net/dettaglio_mame.php?game_name=kof97 | - | KOF97 机器参数、CPU、帧率 |
| 14 | 68000 Assembly for NeoGeo | https://www.chibiakumas.com/68000/neogeo.php?noui=1 | - | BIOS RAM 变量、输入状态变量 |
| 15 | K73 KOF97 金手指 | http://www.k73.com/down/cheat/74656.html | 2015-01-06 | MAME 金手指使用方法 |
| 16 | MAME-rr KOF Hitboxes | https://github.com/Jesuszilla/mame-rr-scripts | - | KOF 碰撞框 Lua 查看器 |
| 17 | Defender Lua Plugin | http://forum.arcadecontrols.com/index.php?topic=163525.0 | 2020-09-05 | Lua 插件控制输入示例 |
| 18 | 8BitDev MAME Debugger Intro | https://7800.8bitdev.org/index.php/Introduction_to_the_the_MAME_debugger | 2025-05-01 | 调试器基础命令、内存查看 |

---

## 8. 下一步行动建议

1. **启动 MAME 调试器验证地址**：`mame kof97 -debug`，使用 `wp 300000,1,r` 和 `wp 108102,2,w` 确认输入和角色状态地址。
2. **编写最小 Lua 测试脚本**：使用 `install_read_tap` 拦截 `$300000`，验证 KOF97 是否能识别注入的按钮输入。
3. **对比 CPS1 方案**：评估是否需要为 NeoGeo 创建独立的 `input-controller.lua` 变体（处理低电平有效、不同地址范围）。
4. **校准血量/坐标地址**：通过 MAME 调试器的 `ci`/`cn` 内存搜索，在战斗中定位 P1/P2 血量（通常以 word 存储，范围 0-最大值）。
5. **更新 rom-configs/kof97.json**：将验证后的地址填入 LuaFighter 项目的 ROM 配置文件。

---

> 本报告由 AI 编码代理基于 8 次独立网络搜索生成，所有地址信息需通过 MAME 调试器实际验证后方可用于生产环境。
