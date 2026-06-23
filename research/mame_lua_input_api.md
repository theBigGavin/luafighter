# MAME Lua API 输入控制研究报告

> 研究日期：2026-06-23  
> MAME 版本：0.288（重点）  
> 目标：梳理 MAME Lua 脚本控制游戏输入的所有可行方式，重点解决 NeoGeo/CPS1 等平台上的注入难题。

---

## 目录

1. [概述](#1-概述)
2. [方法一：`field:set_value()` — 标准字段注入](#2-方法-fieldset_value--标准字段注入)
3. [方法二：`port:write(value, mask)` — 端口输出写入](#3-方法-portwritevalue-mask--端口输出写入)
4. [方法三：`install_read_tap` — 内存读路径拦截](#4-方法-installreadtap--内存读路径拦截)
5. [方法四：`install_write_tap` — 内存写路径拦截](#5-方法-installwritetap--内存写路径拦截)
6. [方法五：直接内存写入（`write_direct_u8` 等）](#6-方法五直接内存写入)
7. [方法六：`natkeyboard:post()` — 键盘事件模拟](#7-方法六natkeyboardpost--键盘事件模拟)
8. [各平台适用性与已知问题](#8-各平台适用性与已知问题)
   - [CPS1 (Capcom System 1)](#cps1)
   - [NeoGeo](#neogeo)
   - [其他平台](#其他平台)
9. [实际代码示例](#9-实际代码示例)
10. [引用来源](#10-引用来源)

---

## 1. 概述

MAME 从 0.2xx 系列开始内置 Lua 5.3 脚本引擎，允许外部脚本读取模拟器状态、修改内存、绘制覆盖层，以及**控制输入**。Lua 脚本可以通过 `-autoboot_script` 参数加载，或作为插件（`-plugin`）运行。

控制游戏输入的核心路径有两条：
- **高层**：通过 `ioport_manager` 操作 `I/O port` 和 `field`，调用 `field:set_value()`。
- **底层**：通过 `address_space` 的 `install_read_tap` / `install_write_tap` 在内存/总线层面拦截数据，或直接用 `write_direct_*` 修改内存。

**关键结论**：`field:set_value()` 在**大多数标准平台**上工作正常，但在**CPS1**等使用 `IP_ACTIVE_LOW` 且走特殊 I/O 芯片（CPS-A/B）的平台上，内存映射的输入端口无法通过 `set_value` 注入，必须使用 `install_read_tap` 在 CPU 读取路径上拦截并修改返回值。NeoGeo 的 `field:set_value()` 经实测可直接工作。

---

## 2. 方法：`field:set_value()` — 标准字段注入

### API 定义

```lua
field:set_value(value)
```

- **作用**：设置 I/O port field 的值，覆盖正常的玩家输入。
- **数字字段**：`value` 与零比较，非零视为按下，零视为释放。
- **模拟字段**：`value` 必须右对齐且在正确范围内。
- **清除覆盖**：`field:clear_value()` 恢复常规行为。

### 官方文档确认

> "Set the value of the I/O port field. For digital fields, the value is compared to zero to determine whether the field should be active."  
> — [Lua Input System Classes](https://docs.mamedev.org/luascript/ref-input.html) [2026-06-23]

### 开发者确认（ACTIVE_HIGH/LOW 无关）

MAME 开发者 `hap` 在 MAME Testers #9178 中明确说明：

> "IO port field `set_value(1)` will 'press' a button no matter if it's active low or high."  
> — [MAME Testers 09178](https://mametesters.org/view.php?id=9178&nbn=9) [2025-05-27]

这意味着 `field:set_value(1)` 在 API 层面已经抽象了硬件的 `ACTIVE_HIGH` / `ACTIVE_LOW` 差异。如果注入无效，问题不在于 API 本身，而在于：
1. 目标驱动没有通过标准 `ioport` 读取输入（例如 CPS1 的 `cps1_dsw_r` 自定义读取逻辑）。
2. 游戏代码在特定阶段（如 attract mode）根本没有读取该端口。

### 实际使用示例（MAME  cheat 插件）

```lua
-- 来自 MAME 官方 cheat 插件 (plugins/cheat/init.lua)
for num, entry in pairs(enttab) do
    entry.field:set_value(1)  -- 按下
end
-- ...
for num, entry in pairs(enttab) do
    entry.field:set_value(0)  -- 释放
end
```
— [MAME cheat/init.lua](https://raw.githubusercontent.com/mamedev/mame/master/plugins/cheat/init.lua) [2026-06-23]

### 限制

- **仅适用于标准 ioport 驱动**：如果游戏驱动使用自定义回调（如 CPS1 的 `cps1_input_r` / `cps1_dsw_r`），`set_value` 修改的 `ioport_field` 内部状态不会传递到该回调的返回值中。
- **无法直接修改内存映射 I/O**：当游戏 CPU 直接读取内存地址获取输入数据（如 CPS1 从 `0x800000` 读取 IN1），`field:set_value` 不会修改该内存地址的返回数据，因为读取路径已经绕过 `ioport` 的常规字段值。

---

## 3. 方法：`port:write(value, mask)` — 端口输出写入

### API 定义

```lua
port:write(value, mask)
```

> "Write to the I/O port **output fields** that are set in the specified mask. Note that this **does not set values for input fields**."  
> — [Lua Input System Classes](https://docs.mamedev.org/luascript/ref-input.html) [2026-06-23]

### 结论

`port:write()` **不能用于控制玩家输入**。它只能写入输出字段（如 lamps、coin counters、dip switches 等），对按钮/摇杆等输入字段无效。不要将其作为 `field:set_value` 的替代方案。

---

## 4. 方法：`install_read_tap` — 内存读路径拦截

### API 定义

```lua
space:install_read_tap(start, end, name, callback)
```

- **作用**：在指定地址空间的读操作路径上安装一个透传处理程序（pass-through handler）。
- **回调签名**：`function(offset, data, mask)`，返回一个整数可修改读取到的数据，不返回则保持原样。
- **关键限制**：回调在 MAME 内存系统内部执行，**绝对不能**在回调中调用 `print()`、`io.open()`、`log` 等 I/O 操作，否则 tap 会被**静默禁用**。

### 官方文档

> "Installs a pass-through handler that will receive notifications on reads from the specified range of addresses... To modify the data being read, return the modified value from the callback function as an integer."  
> — [Lua Memory System Classes](https://docs.mamedev.org/luascript/ref-mem.html) [2026-06-23]

### 适用场景

当游戏驱动使用**自定义内存映射回调**读取输入时，`install_read_tap` 是唯一的 Lua 注入手段。典型例子：
- **CPS1**：`cps1_input_r` / `cps1_dsw_r` 从 `0x800000` / `0x800018` 返回 IN1/IN0。
- **某些 NeoGeo 辅助芯片**：输入可能通过自定义内存映射返回。

### 实测代码（CPS1-SF2CE）

```lua
local maincpu = manager.machine.devices[":maincpu"]
local space = maincpu.spaces["program"]

-- 拦截 IN1 (0x800000-0x800007)，玩家方向+按钮
local tap_in1 = space:install_read_tap(0x800000, 0x800007, "luafighter_in1",
  function(offset, data, mask)
    local modified = data
    -- 按位清除要"按下"的按钮（CPS1 IN1 是 active-low）
    for m, _ in pairs(active_in1_masks) do
      modified = modified & ~m
    end
    return modified
  end)

-- 拦截 IN0 (0x800018-0x80001F)，投币/开始
-- 注意：必须覆盖整个 handler 范围，子范围 tap 会被 MAME 拒绝
local tap_dsw = space:install_read_tap(0x800018, 0x80001F, "luafighter_dsw",
  function(offset, data, mask)
    local modified = data
    -- IN0 在高字节（cps1_dsw_r 返回 (IN0 << 8) | dsw）
    for m, _ in pairs(active_in0_masks) do
      modified = modified & ~(m << 8)
    end
    return modified
  end)
```
— 基于 LuaFighter `lua-scripts/utils/input-controller.lua` 实测验证 [2026-06-23]

### 关键限制

| 限制 | 说明 |
|------|------|
| **禁止 I/O 操作** | 回调中 `print`/`io.open`/`log` 会导致 tap 被静默移除 |
| **地址范围必须覆盖整个 handler** | 如果底层是 `0x800018-0x80001F` 一个 handler，不能只 tap `0x800018-0x800019` |
| **无法修改未读取的地址** | 如果游戏代码不读该地址，tap 不会触发 |
| **attract mode 不检测输入** | CPS1 在 attract demo 期间根本不检查 IN0，此时 tap 修改无意义 |

---

## 5. 方法：`install_write_tap` — 内存写路径拦截

### API 定义

```lua
space:install_write_tap(start, end, name, callback)
```

- 与 `install_read_tap` 对称，拦截写入操作。
- 回调返回修改后的值，可改变游戏实际写入的数据。

### 使用场景

**不是直接用于输入注入**，而是用于：
- 修改游戏逻辑（如让 Puzzle Bobble 的旋转角度翻倍）
- 从 NeoGeo 游戏内存中抓取调试日志（通过写信号地址触发 Lua 读取）

### 示例（Matt Greer 的 NeoGeo 调试）

```lua
local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local NG_CONSOLE_BUFFER = 0x10d000
local NG_CONSOLE_SIG = 0x10d000 + 80 + 2

function ng_to_stdout()
  local str = mem:read_range(NG_CONSOLE_BUFFER, NG_CONSOLE_BUFFER + 80, 8)
  print(str)
end

ngstdout_handler = mem:install_write_tap(
  NG_CONSOLE_SIG, NG_CONSOLE_SIG + 1, "ngstdout", ng_to_stdout)
```
— [Matt Greer: MAME Lua for Better Retro Dev](https://www.mattgreer.dev/blog/mame-lua-for-better-retro-dev/) [2024-03-05]

---

## 6. 方法五：直接内存写入

### API

```lua
space:write_direct_u8(addr, val)
space:write_direct_u16(addr, val)
space:write_u8(addr, val)
space:write_u16(addr, val)
-- 等
```

### 限制

- 只能写入**真实的 RAM/可写内存地址**。
- 对于**内存映射 I/O（MMIO）**，直接写入地址通常不会触发游戏逻辑，因为游戏 CPU 读取的是**寄存器值**，而非 RAM 值。即使写入 `0x800000`（CPS1 IN1 地址），CPU 下一次读该地址时，仍会走 `cps1_input_r` 回调，读取的是硬件寄存器状态，不是 RAM。
- 因此，直接内存写入**不适合输入注入**，除非你知道游戏内部使用 RAM 变量作为输入缓冲区（非常少见）。

### 示例（Defender 插件，直接写内存控制角度）

```lua
if inp:code_pressed(inp:code_from_token("KEYCODE_LEFT")) then
  manager:machine().devices[":maincpu"].spaces["program"]:write_direct_u8(0xA0BB, 0xFD)
  btn_thrust.field:set_value(1)
end
```
— [MAME LUA - Defender 8-way control Plugin](http://forum.arcadecontrols.com/index.php?topic=163525.0) [2020-09-05]

这个例子中，`0xA0BB` 是 Defender 的**内存变量**（飞船角度），不是 I/O 端口，所以直接写入有效。但对于标准街机输入，直接内存写基本无效。

---

## 7. 方法六：`natkeyboard:post()` — 键盘事件模拟

### API

```lua
manager.machine.natkeyboard:post("text")
manager.machine.natkeyboard:post_coded("{ENTER}")
```

### 限制

- 仅适用于有**键盘字符绑定**的模拟系统（如电脑、终端、打字机等）。
- 街机游戏（CPS1/NeoGeo）没有键盘输入，此方法无效。
- MAME Testers #9178 的测试也证实 `natkeyboard:post` 对街机 I/O 端口无影响。

---

## 8. 各平台适用性与已知问题

### CPS1 (Capcom System 1)

| 方法 | 玩家控制 (IN1) | 系统按钮 (IN0) | 说明 |
|------|---------------|---------------|------|
| `field:set_value()` | ❌ 无效 | ❌ 无效 | CPS1 使用 `cps1_input_r` / `cps1_dsw_r` 自定义回调，`set_value` 不传递到返回值 |
| `port:write()` | ❌ 无效 | ❌ 无效 | 文档明确说明对 input fields 无效 |
| `install_read_tap` | ✅ 有效 | ⚠️ 有陷阱 | IN1 读 tap 工作；IN0 的 tap 能修改数据但游戏在 attract 期间不检查 IN0 |
| 直接内存写 | ❌ 无效 | ❌ 无效 | MMIO 不走 RAM |

**CPS1 已知问题**：
1. **Attract Demo 不检测 IN0**：游戏在 attract 阶段（约 25-30 秒）根本不读取 coin/start 输入，即使 tap 成功修改了返回值，也无法触发投币/开始。
2. **Coin/Start 路径可能独立于内存读取**：有推测认为 CPS-A 芯片可能通过硬件中断或内部寄存器直接管理 coin 检测，不完全依赖 `cps1_dsw_r` 的返回值。
3. **投币锁存器 `0x800030`**：写入 `cps1_coinctrl_w` 也无法触发游戏识别投币。

**LuaFighter 实测结论**：CPS1 的 IN1（玩家方向+按钮）通过 `install_read_tap` 在 `0x800000-0x800007` 成功注入；IN0（投币/开始）目前**无已知 Lua 注入方案**。

### NeoGeo

| 方法 | 有效性 | 说明 |
|------|--------|------|
| `field:set_value()` | ✅ 有效 | 可直接设置 NeoGeo ioport field，能拉低 active-low 位。必须显式 `set_value(0)` 释放 |
| `port:write()` | ❌ 无效 | 对 input fields 无效 |
| `install_read_tap` | ✅ 有效（备用） | 如果 `set_value` 遇到问题，可通过内存读 tap 修改输入数据 |
| 直接内存写 | ❌ 无效 | MMIO 不走 RAM |

**NeoGeo 已知问题**：
1. **无需 read-tap**：NeoGeo 的 `field:set_value()` 在 MAME 0.288 上实测可直接工作。方向键和按钮在同一 port 的不同 bit 上，允许组合输入。
2. **必须显式释放**：`set_value(1)` 按下后，必须调用 `set_value(0)` 释放，否则按键保持按下。
3. **Coin/Start 可能有效**：NeoGeo 的 coin/start 也是标准 ioport，理论上 `set_value` 有效，但需确认具体游戏是否在 attract 阶段读取。

**LuaFighter 实测代码**：
```lua
-- NeoGeo 路径：直接使用 field:set_value
local port = manager.machine.ioport.ports[":P1"]
if port then
  local field = port.fields["P1 Button 1"]
  if field then
    field:set_value(1)  -- 按下
    -- ... 稍后释放 ...
    field:set_value(0)    -- 释放
  end
end
```
— `lua-scripts/utils/input-controller.lua` [LuaFighter 项目]

### 其他平台

- **标准 MAME 驱动**（如 Pac-Man、Galaga 等）：`field:set_value()` 是最简单可靠的方式。
- **使用自定义 I/O 芯片的驱动**（如某些 Konami、Sega 基板）：可能需要 `install_read_tap` 作为备选。
- **电脑/主机模拟**（如 NES、SNES）：`field:set_value()` 通常有效，因为这些驱动使用标准 ioport。

---

## 9. 实际代码示例

### 示例 A：通用按钮注入（标准驱动）

```lua
function press_button(port_tag, field_name)
  local port = manager.machine.ioport.ports[port_tag]
  if not port then return false end
  local field = port.fields[field_name]
  if not field then return false end
  field:set_value(1)  -- 按下
  return true
end

function release_button(port_tag, field_name)
  local port = manager.machine.ioport.ports[port_tag]
  if not port then return false end
  local field = port.fields[field_name]
  if not field then return false end
  field:set_value(0)  -- 释放
  return true
end

-- 使用
press_button(":IN1", "P1 Button 1")
```

### 示例 B：CPS1 玩家控制注入（install_read_tap）

```lua
local maincpu = manager.machine.devices[":maincpu"]
local space = maincpu.spaces["program"]
local cps_state = { in1 = {}, in0 = {} }

-- 安装 IN1 读 tap（玩家方向+按钮）
local tap = space:install_read_tap(0x800000, 0x800007, "cps1_in1",
  function(offset, data, mask)
    local modified = data
    -- active-low: 按位清除表示按下
    for m, _ in pairs(cps_state.in1) do
      modified = modified & ~m
    end
    return modified
  end)

-- 按下 P1 按钮1 (mask = 0x0010)
cps_state.in1[0x0010] = true
-- 释放
cps_state.in1[0x0010] = nil
```

### 示例 C：NeoGeo 按钮注入（field:set_value）

```lua
local function neogeo_press(player, button)
  local port_tag = (player == 1) and ":P1" or ":P2"
  local field_name = string.format("P%d Button %d", player, button)
  local port = manager.machine.ioport.ports[port_tag]
  if port then
    local field = port.fields[field_name]
    if field then
      field:set_value(1)
    end
  end
end

local function neogeo_release(player, button)
  local port_tag = (player == 1) and ":P1" or ":P2"
  local field_name = string.format("P%d Button %d", player, button)
  local port = manager.machine.ioport.ports[port_tag]
  if port then
    local field = port.fields[field_name]
    if field then
      field:set_value(0)
    end
  end
end
```

### 示例 D：检测平台并选择注入策略

```lua
function auto_inject(platform, player, button, press)
  if platform == "cps1" then
    -- 使用 read_tap 状态机
    local mask = CPS1_BUTTON_MASKS[player][button]
    cps_state.in1[mask] = press and true or nil
  elseif platform == "neogeo" then
    -- 使用标准 field:set_value
    local port = manager.machine.ioport.ports[(player==1) and ":P1" or ":P2"]
    if port then
      local field = port.fields[button]
      if field then field:set_value(press and 1 or 0) end
    end
  else
    -- 通用 fallback
    local port = manager.machine.ioport.ports[":IN1"]
    if port then
      local field = port:field(button_mask)
      if field then field:set_value(press and 1 or 0) end
    end
  end
end
```

---

## 10. 引用来源

| 来源 | URL | 日期 | 关键信息 |
|------|-----|------|----------|
| MAME Lua Input System Docs | https://docs.mamedev.org/luascript/ref-input.html | 2026-06-23 | `field:set_value`, `port:write` 官方定义，确认 `port:write` 不作用于 input fields |
| MAME Lua Memory System Docs | https://docs.mamedev.org/luascript/ref-mem.html | 2026-06-23 | `install_read_tap` / `install_write_tap` 定义，tap 回调不能是 coroutine |
| MAME Testers #9178 | https://mametesters.org/view.php?id=9178&nbn=9 | 2025-05-27 | 开发者 `hap` 确认 `set_value(1)` 对 active-low/high 都能正确按下按钮 |
| Matt Greer Blog | https://www.mattgreer.dev/blog/mame-lua-for-better-retro-dev/ | 2024-03-05 | NeoGeo 上使用 `install_write_tap` 做调试通信；`install_read_tap` / `install_write_tap` 示例 |
| Matt Greer Blog (Debug) | https://www.mattgreer.dev/blog/mame-debugging/ | 2024-02-02 | `install_read_tap` / `install_write_tap` 用于内存读写拦截的详细说明 |
| MAME Cheat Plugin Source | https://raw.githubusercontent.com/mamedev/mame/master/plugins/cheat/init.lua | 2026-06-23 | 官方 cheat 插件使用 `entry.field:set_value(1/0)` 作为标准输入注入方式 |
| MAME Defender Plugin | http://forum.arcadecontrols.com/index.php?topic=163525.0 | 2020-09-05 | 使用 `write_direct_u8` 修改 Defender 内存变量（非 I/O 端口）；`field:set_value` 用于 thrust 按钮 |
| MAME Autofire Plugin | http://forum.arcadecontrols.com/index.php?topic=155050.0 | 2018-01-27 | `button.field:set_value(1)` / `set_value(0)` 在 autofire 中的使用 |
| MAME Lua Plugins Thread | https://forum.arcadecontrols.com/index.php?topic=151810.0 | 2017-01-27 | 提及 `ioport.write()` 可用于设置 coin 端口，但具体指 `port:write`（对 input 无效）还是其他方式存疑 |
| MAME Issue #7213 | https://github.com/mamedev/mame/issues/7213 | 2020-09-11 | 关于获取 `Input (general)` 绑定状态的讨论，与 `ioport().ports` 读取相关 |
| LuaFighter input-controller.lua | /Users/gavin/playground/gameplay/luafighter/lua-scripts/utils/input-controller.lua | 2026-06-23 | CPS1 read-tap 实测方案 + NeoGeo `field:set_value` 实测方案 |
| LuaFighter cps1-input-limitation.md | /Users/gavin/playground/gameplay/luafighter/docs/cps1-input-limitation.md | 2026-06-23 | CPS1 IN0/IN1 注入限制分析，attract mode 不检测 IN0 的实测结论 |

---

## 附录：MAME 输入注入方法速查表

| 方法 | 适用层级 | 对 Input Fields 有效 | 对 MMIO 有效 | 主要限制 |
|------|---------|---------------------|-------------|----------|
| `field:set_value()` | ioport field | ✅ 是 | ❌ 否（取决于驱动） | 驱动使用自定义回调时可能无效 |
| `port:write()` | ioport port | ❌ 否 | ❌ 否 | 仅用于 output fields |
| `install_read_tap` | address space | ✅ 是（间接） | ✅ 是 | 回调中禁止 I/O 操作；需覆盖完整 handler 范围 |
| `install_write_tap` | address space | ❌ 否（通常） | ✅ 是 | 用于修改写入数据，非直接输入控制 |
| `write_direct_*` | address space | ❌ 否 | ❌ 否 | 仅写入 RAM，MMIO 寄存器不走 RAM |
| `natkeyboard:post()` | keyboard | ❌ 否 | ❌ 否 | 仅适用于有键盘绑定的系统 |
