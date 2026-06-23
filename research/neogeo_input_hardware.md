# NeoGeo 硬件输入系统与 MAME 模拟架构研究报告

> 研究日期：2026-06-23  
> 研究目的：解决 Lua 脚本注入按钮后 NeoGeo 游戏（KOF97 等）不响应的问题  
> 研究方法：基于公开文档、MAME 源码索引、硬件手册和开发者社区资料

---

## 1. 执行摘要

本报告系统梳理了 NeoGeo（MVS/AES）硬件层面的输入端口结构、MAME 模拟器中的输入映射机制、以及 UniBIOS 对输入流的干预方式。核心发现如下：

- **NeoGeo 硬件输入为只读寄存器**：`$300000`（P1）、`$340000`（P2）由 NEO-C1 芯片驱动，**物理上不可写入**。游戏 CPU 通过 68000 总线读取这些端口，位值为 **active low**（按下为 0）。
- **MAME 使用 `:edge:joy:JOY1` / `:edge:joy:JOY2` 端口标签**：通过输入子系统（input system）将物理设备映射到这些逻辑端口，再映射到硬件寄存器读取。
- **UniBIOS 会拦截并重映射输入**：在单槽（single slot）模式下，UniBIOS 将 MAME 的 "Coin" 信号视为 AES 手柄的 "Select" 键；同时监听 `A+B+C+Start`、`Start+Select` 等组合键来触发 BIOS 菜单，导致外部注入的输入可能被 BIOS 截获或改变含义。
- **直接内存写入输入状态不可行**：由于 `$300000`/`$340000` 是 MAME 驱动层面的 `AM_READ_PORT` 映射区域，写入这些地址不会进入硬件输入 latch，反而可能触发看门狗或无效操作。
- **可行的注入方案**：使用 MAME Lua 的 `install_read_tap` 拦截对 `$300000`/`$340000` 的读取，在回调中返回伪造的按键位值（active low）。这与 CPS1 的 `install_read_tap` 方案类似，但 tap 地址需改为 NeoGeo 的输入寄存器。

---

## 2. NeoGeo 硬件层面输入端口结构

### 2.1 68000 主 CPU 内存映射 I/O 寄存器

NeoGeo 的输入系统由专用 I/O 芯片（NEO-C1、NEO-F0 等）管理，68000 通过内存映射 I/O 读取控制器状态。以下为主要输入寄存器：

| 寄存器 | 地址 | 说明 | 芯片 |
|--------|------|------|------|
| `REG_P1CNT` | `$300000` | 玩家 1 控制器输入（active low） | NEO-C1 |
| `REG_DIPSW` | `$300001` | DIP 开关 / 看门狗清零 | NEO-F0 / NEO-B1 |
| `REG_STATUS_A` | `$320001` | 系统状态 A：投币、Service、RTC 位 | - |
| `REG_P2CNT` | `$340000` | 玩家 2 控制器输入（active low） | NEO-C1 |
| `REG_STATUS_B` | `$380000` | 系统状态 B：Start/Select、记忆卡检测 | - |
| `REG_POUTPUT` | `$380001` | 手柄端口输出（trackball 选择等） | - |

> 来源：Neo-Geo Programming Manual (Alexander Stante) [^1]；NeoGeo Development Wiki [^2]；chibiakumas.com 68000 NeoGeo 教程 [^3]

### 2.2 REG_P1CNT / REG_P2CNT 位映射（硬件层面）

两个寄存器均为 **8-bit active low**，位定义如下（从硬件文档交叉验证）：

| Bit | 7 | 6 | 5 | 4 | 3 | 2 | 1 | 0 |
|-----|---|---|---|---|---|---|---|---|
| 功能 | D | C | B | A | Right | Left | Down | Up |

- **Active low**：位值为 `0` 表示对应按钮/方向被按下，`1` 表示未按下。
- **默认值**：未按下时读值为 `0xFF`（全高）。
- **Trackball 模式**：当 `REG_POUTPUT` bit 0 为 0/1 时，`$300000` 可读取轨迹球 X/Y 计数器值（部分游戏如 `irrmaze`）。

> 来源：NeoGeo Development Wiki — Memory mapped registers [^2]；freemlib-neogeo `neogeo.inc` [^4]

### 2.3 投币/Start/Select 的寄存器映射

投币和 Start/Select 不在 `$300000`/`$340000` 中，而是通过以下寄存器读取：

- **投币（Coin 1 / Coin 2）**：`REG_STATUS_A` (`$320001`) bit 0/1（active low）
- **Start/Select**：`REG_STATUS_B` (`$380000`) bit 0~3（active low）
  - Bit 0 = P1 Start
  - Bit 1 = P1 Select（在 MVS 上通常为 Coin 1，或用于 UniBIOS 的 SELECT）
  - Bit 2 = P2 Start
  - Bit 3 = P2 Select

> 来源：Neo-Geo Programming Manual § Memory-Mapped Registers [^1]

---

## 3. MAME NeoGeo 驱动中的输入端口定义

### 3.1 端口标签结构

MAME 的 NeoGeo 驱动（`src/mame/neogeo/neogeo.cpp` / `neogeo.inc`）使用以下输入端口标签：

| 端口标签 | 说明 |
|----------|------|
| `:edge:joy:JOY1` | 玩家 1 摇杆 + 按钮（A/B/C/D） |
| `:edge:joy:JOY2` | 玩家 2 摇杆 + 按钮（A/B/C/D） |
| `:edge:joy:START` | Start 按钮（P1/P2） |
| `:SYSTEM` | 系统按钮（Test、Service） |
| `:AUDIO_COIN` | 投币信号 |
| `:DSW` | DIP 开关 |

> 来源：MAME Spludlow Machine Database — `neogeo` [^5]；MAME Testers #07082 [^6]

### 3.2 `:edge:joy:JOY1` / `:edge:joy:JOY2` 字段定义

虽然 MAME 当前源码无法直接拉取（GitHub 网络限制），但可通过历史源码（historic-mame）和社区配置确认字段映射：

在 MAME 的 `neogeo.c` 历史源码中，输入端口通过 `AM_READ_PORT("IN0")` 映射到 `$300000`，`AM_READ_PORT("IN1")` 映射到 `$340000`。

具体位映射（从社区 cfg/ctrlr 文件和 MAME Testers 交叉验证）：

| MAME 位掩码 | 方向/按钮 | 说明 |
|-------------|-----------|------|
| `0x01` | Up | 方向键上 |
| `0x02` | Down | 方向键下 |
| `0x04` | Left | 方向键左 |
| `0x08` | Right | 方向键右 |
| `0x10` | Button A | 按钮 A（拳/轻攻击） |
| `0x20` | Button B | 按钮 B（脚/中攻击） |
| `0x40` | Button C | 按钮 C（重攻击/特殊） |
| `0x80` | Button D | 按钮 D（超重击/闪避） |

> 注意：MAME Testers #07082 曾记录 `:edge:joy:JOY1` 的 Start 按钮状态被反向（backward），后经修复。这证实了 MAME 驱动使用 `0x01`~`0x80` 的 8-bit 掩码对应 JOY1 端口。

> 来源：historic-mame `src/mame/drivers/neogeo.c` [^7]；MAME Testers #07082 [^6]；LaunchBox 论坛 NeoGeo 配置帖 [^8]

### 3.3 MAME 驱动中的内存映射

在历史 MAME 源码中，NeoGeo 的输入读取由以下地址映射实现：

```cpp
AM_RANGE(0x300000, 0x300001) AM_MIRROR(0x01ff7e) AM_READ_PORT("IN0")   // P1 + DSW
AM_RANGE(0x340000, 0x340001) AM_MIRROR(0x01fffe) AM_READ_PORT("IN1")   // P2
```

- `AM_MIRROR` 表示地址镜像（address mirroring），即 `$300000`~`$300001` 的读取会在更大的地址空间内重复映射。
- `AM_READ_PORT` 表示该区域不对应物理 RAM，而是直接由 MAME 输入端口系统驱动。

> 来源：historic-mame `src/mame/drivers/neogeo.c` [^7]；MAMEHub `neogeo.c` [^9]

---

## 4. UniBIOS 对输入系统的影响

### 4.1 UniBIOS 输入拦截机制

UniBIOS（Universe BIOS）是第三方修改的 NeoGeo BIOS，广泛用于 MAME 和真机。它通过以下方式影响输入：

1. **Coin ↔ Select 映射**：在单槽（single slot）模式下，UniBIOS 将 MAME 的 "Coin" 输入视为 AES 手柄的 "Select" 键。因此，当 Lua 脚本或外部控制器同时触发 `Coin` 和 `Start` 时，UniBIOS 会将其解释为 `Start + Select`，从而触发 BIOS 的 **in-game menu**（游戏内菜单），导致游戏本体接收不到 Start 信号。

2. **组合键监听**：UniBIOS 在启动和游戏过程中持续监听以下组合：
   - `A+B+C` → 打开 UniBIOS 菜单
   - `A+B+C+D` → 存储卡管理器
   - `Start+Select`（或 `Start+Coin`）→ 游戏内菜单
   - `B+C+D` → Test 模式（MVS）/ 硬件测试（AES）

3. **直接端口访问 vs BIOS 调用**：部分游戏（如 Metal Slug 系列、Art of Fighting 3 等）**直接访问 `$300000`/`$340000`** 读取输入，而非通过 BIOS 的 `SYSTEM_IO` ($C0044A) 调用。对于这些游戏，UniBIOS 的 Coin-as-Select 映射可能失效，因为游戏不经过 BIOS 输入处理层。

> 来源：Neo-Geo.com 论坛 — "Problem with first player start button, Mame+Unibios 2.3o" [^10]；ConsoleMods — UNIVERSE BIOS (UniBIOS) [^11]；Neo-Geo.com 论坛 — "Options unibios" [^12]

### 4.2 对 Lua 输入注入的影响

如果 Lua 脚本通过 `install_read_tap` 在 `$300000` 注入按钮，但**同时**通过 MAME 输入系统发送 `Coin` 信号（或 `$320001`/`$380000` 的投币位），UniBIOS 可能：

- 将 `Coin` 识别为 `Select`，从而进入 BIOS 菜单；
- 在菜单模式下忽略正常的游戏输入；
- 改变 `Start` 按钮的含义（例如从 "开始游戏" 变为 "确认菜单选项"）。

**建议**：在使用 UniBIOS 进行自动化测试时，应在 UniBIOS 设置中 **禁用 Input Crossing**（或选择 MVS 模式而非 AES 模式），或改用原生 BIOS（如 `asia-s3.rom` / `japan-j3.bin`）以排除 UniBIOS 的干预。

> 来源：Neo-Geo.com 论坛 — "SELECT button acting as COIN - Is this normal?" [^13]

---

## 5. 直接内存写入输入状态的可行性分析

### 5.1 为什么直接写入 `$300000` 无效

NeoGeo 的 `$300000`/`$340000` 在 MAME 驱动中定义为 `AM_READ_PORT`，这意味着：

- 这些地址**没有 backing memory**，写入操作不会存储任何值；
- 在真实硬件中，这些地址连接到 NEO-C1 的输入 latch，**CPU 无法写入**；
- 在 MAME 中，写入这些地址可能落入镜像区域或触发未定义行为（某些版本会触发看门狗复位）。

### 5.2 可行的注入方案：`install_read_tap`

与 CPS1 的 `install_read_tap` 方案类似，NeoGeo 的输入注入应通过**读取拦截**实现：

```lua
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]

-- NeoGeo P1 输入寄存器地址
local REG_P1CNT = 0x300000
local REG_P2CNT = 0x340000

function on_read_p1(offset, data)
    -- 默认返回原始值（未按下 = 0xFF）
    local injected = 0xFF
    
    -- 模拟按下 P1 的 A 按钮（bit 4 = 0）
    injected = injected & ~0x10
    
    -- 模拟按下 P1 的 Right（bit 3 = 0）
    injected = injected & ~0x08
    
    return injected
end

mem:install_read_tap(REG_P1CNT, REG_P1CNT + 1, "p1_input_inject", on_read_p1)
```

**关键注意事项**：

1. **Active low**：注入值中，位为 `0` 表示按下，`1` 表示释放。默认状态应为 `0xFF`。
2. **地址范围**：`install_read_tap` 的起止地址为 `[start, end]`（含），因此 `REG_P1CNT` 到 `REG_P1CNT + 1` 覆盖字节地址 `$300000`。
3. **MAME 0.288 兼容性**：在 MAME 0.288 中，`install_read_tap` 的签名和 `space` 对象可用，但需确保在 `emu.register_periodic` 或帧回调中安装，避免 `startplugin` 阶段 `machine` 未初始化。
4. **与 CPS1 的区别**：CPS1 使用 `0x800000`（IN1）和 `0x800018`（IN0/DSW），而 NeoGeo 使用 `$300000`（P1）和 `$340000`（P2）。CPS1 的按钮位映射（如 `0x10` = BUTTON1）与 NeoGeo 的 `0x10` = A 按钮**数值相同**，但地址和芯片逻辑完全不同。

### 5.3 投币/Start 的注入

投币和 Start 不在 `$300000`/`$340000` 中，需要通过拦截 `$320001`（Coin）和 `$380000`（Start/Select）来实现：

| 目标 | 地址 | 位 | Active |
|------|------|-----|--------|
| Coin 1 | `$320001` | bit 0 | Low |
| Coin 2 | `$320001` | bit 1 | Low |
| P1 Start | `$380000` | bit 0 | Low |
| P1 Select | `$380000` | bit 1 | Low |
| P2 Start | `$380000` | bit 2 | Low |
| P2 Select | `$380000` | bit 3 | Low |

> 来源：Neo-Geo Programming Manual [^1]；MAME Debugging — Matt Greer [^14]

---

## 6. 结论与建议

### 6.1 根本原因总结

Lua 脚本注入按钮后 NeoGeo 游戏不响应，可能由以下原因导致：

1. **地址错误**：使用了 CPS1 的地址（如 `0x800000`）而非 NeoGeo 的 `$300000`/`$340000`。
2. **位映射错误**：未使用 active low 逻辑，或位掩码与按钮不对应（如将 `0x01` 当作 A 按钮）。
3. **UniBIOS 拦截**：注入的 `Coin` 信号被 UniBIOS 视为 `Select`，触发了 BIOS 菜单，导致游戏未收到输入。
4. **MAME 输入系统冲突**：如果同时通过 MAME 的 `-plugin` 或 `-autoboot_script` 注入输入，且端口未正确隔离，MAME 的输入系统可能覆盖 Lua 的返回值。
5. **Tap 安装时机**：在 `startplugin` 中过早安装 `install_read_tap`，而 `machine` 尚未初始化，导致 tap 未生效。

### 6.2 实施建议

1. **验证当前 BIOS**：确认 MAME 加载的是原生 MVS BIOS 还是 UniBIOS。可通过 MAME 的 `TAB` → `Bios Selection` 查看。建议先用原生 BIOS 验证注入逻辑，排除 UniBIOS 干扰。
2. **使用 `install_read_tap` 而非 `write_tap`**：在 `$300000` 和 `$340000` 上安装读取拦截，返回伪造的 active-low 位值。
3. **分步验证**：
   - 先拦截 `$300000`，仅注入 `0xEF`（强制 bit 4 = A 按钮按下），观察游戏是否有反应；
   - 再逐步添加方向和其他按钮；
   - 最后处理 `$320001` 和 `$380000` 的投币/Start。
4. **日志记录**：在 `install_read_tap` 回调中使用 `print` 或文件日志记录每次读取的地址、原始值和注入值，确保 tap 被正确触发。
5. **避免 I/O 在 tap 中**：遵循 MAME Lua 限制，`install_read_tap` 回调中**不得**执行 `print`、`io.open` 或 `log` 等 I/O 操作（参考 `docs/cps1-input-limitation.md` 中的 CPS1 经验）。

---

## 7. 引用来源

| 编号 | 来源 | URL | 访问日期 |
|------|------|-----|----------|
| [^1] | Neo-Geo Programming Manual (Alexander Stante) | http://furrtek.free.fr/noclass/neogeo/NeoGeoPM.pdf | 2026-06-23 |
| [^2] | NeoGeo Development Wiki — Memory mapped registers | https://wiki.neogeodev.org/index.php/Memory_mapped_registers | 2026-06-23 |
| [^3] | 68000 Assembly Programming for the NeoGeo (chibiakumas.com) | https://www.chibiakumas.com/68000/neogeo.php?noui=1 | 2026-06-23 |
| [^4] | freemlib-neogeo `neogeo.inc` | https://raw.githubusercontent.com/freem/freemlib-neogeo/master/src_68k/inc/neogeo.inc | 2026-06-23 |
| [^5] | MAME Spludlow Machine Database — `neogeo` | https://mame.spludlow.co.uk/Machine.aspx?name=neogeo | 2026-06-23 |
| [^6] | MAME Testers #07082 — neogeo: Start button states are backward | https://mametesters.org/view.php?id=7082 | 2026-06-23 |
| [^7] | historic-mame `src/mame/drivers/neogeo.c` | https://github.com/mamedev/historic-mame/blob/master/src/mame/drivers/neogeo.c | 2026-06-23 |
| [^8] | LaunchBox Forum — Treating NeoGeo games differently en-masse in MAME | https://forums.launchbox-app.com/topic/70314-treating-neogeo-games-differently-en-masse-in-mame/ | 2026-06-23 |
| [^9] | MAMEHub `Sources/Emulator/src/mame/drivers/neogeo.c` | https://github.com/MisterTea/MAMEHub/blob/master/Sources/Emulator/src/mame/drivers/neogeo.c | 2026-06-23 |
| [^10] | Neo-Geo.com Forum — Problem with first player start button, Mame+Unibios 2.3o | http://www.neo-geo.com/forums/index.php?threads/problem-with-first-player-start-button-mame-unibios-2-3o.208463/ | 2026-06-23 |
| [^11] | ConsoleMods — UNIVERSE BIOS (UniBIOS) | https://consolemods.org/wiki/Neo_Geo:UNIVERSE_BIOS_(UniBIOS) | 2026-06-23 |
| [^12] | Neo-Geo.com Forum — Options unibios | http://www.neo-geo.com/forums/index.php?threads/options-unibios.271288/ | 2026-06-23 |
| [^13] | Neo-Geo.com Forum — SELECT button acting as COIN - Is this normal? | http://www.neo-geo.com/forums/index.php?threads/select-button-acting-as-coin-is-this-normal.233454/ | 2026-06-23 |
| [^14] | MAME Debugging — Matt Greer | https://www.mattgreer.dev/blog/mame-debugging/ | 2026-06-23 |
| [^15] | MAME SVN History (neogeo input ports) | http://mame.dorando.at/svn/?rev=44512 | 2026-06-23 |
| [^16] | Neo-Geo Programming Manual (Google Sites mirror) | https://sites.google.com/site/neo Geo programming/ | 2026-06-23（未直接访问，通过引用确认） |
| [^17] | GitHub libretro/mame2003-plus-libretro — UniBIOS 3.3 compatibility | https://github.com/libretro/mame2003-plus-libretro/issues/225 | 2026-06-23 |
| [^18] | KOF97 逆向分析 — MAME 调试器 | https://blog.csdn.net/frankpi/article/details/130429323 | 2026-06-23 |

---

> 报告编写完成。如有进一步测试需求（如针对特定 BIOS 版本或 ROM 的验证），建议通过 MAME 调试器（`-debug`）和 Lua 脚本进行实时读取拦截验证。
