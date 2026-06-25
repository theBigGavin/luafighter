# MAME 模拟工作流程、内存管理与状态管理机制研究报告

> 研究时间：2026-06-25  
> 研究目标：系统性理解 MAME 内部工作机制，为 LuaFighter 提供架构改进依据

---

## 一、MAME 模拟工作流程

### 1.1 核心架构：多 CPU 时间切片执行

MAME 不是真正的并行模拟，而是通过**时间切片**来模拟多 CPU 系统：

```
真实硬件：                    MAME 模拟：
CPU A ──┐                    CPU A 执行 (0-100us)
       │    并行              CPU B 执行 (0-100us)  ← 收到的是 A 结束后的信号
CPU B ──┘                    CPU C 执行 (0-100us)
CPU C ──┘                    视频/音频更新
```

**关键问题**：信号传递存在时间差。如果 CPU A 在 100us 末尾发送信号，CPU B 在 MAME 中要到下一个 100us 切片开始才收到。

**解决方案**：通过更细粒度的时间切片（interleave）和事件系统来减少误差。

### 1.2 执行循环：事件驱动的精确同步

```
while (!done) {
  microseconds = event_time_till_next_event();  // 计算到下一个事件的时间
  for (activecpu = 0; activecpu < totalcpu; activecpu++) {
    cycles = microsec_to_cycles(&Machine->cpu[activecpu], microseconds);
    cpu_execute(cycles);  // 每个 CPU 执行对应周期数
  }
  event_process_next_event();  // 处理事件（中断、定时器等）
}
```

**关键发现**：
- MAME 以**事件**为驱动，不是以帧为单位
- CPU 执行是**指令级**的（fetch → decode → execute → increment counters → pending events）
- 帧更新本身也是一个事件（通过 timer 触发）

### 1.3 单帧内的执行顺序

```
┌─────────────────────────────────────┐
│  1. CPU A 执行 N 个周期              │
│  2. CPU B 执行 N 个周期              │
│  3. CPU C 执行 N 个周期              │
│  4. 定时器系统检查：是否有事件到期？    │
│  5. 如果有，执行事件回调              │
│  6. 检查是否到达帧边界                 │
│  7. 如果是，执行视频更新              │
│     → 触发 register_frame_done      │
│  8. 触发 register_periodic            │
│  9. 检查 throttle（控制帧率）         │
│  10. 返回步骤 1                       │
└─────────────────────────────────────┘
```

**关键理解**：
- `register_periodic` 每帧执行一次，在视频更新**之后**
- `register_frame_done` 在视频绘制完成时执行
- Lua 脚本的执行时机是在 CPU 执行完毕、视频更新之后

---

## 二、MAME 内存管理系统

### 2.1 内存子系统架构（emumem / addrmap）

```
CPU Device
  └── Address Space (program)
        └── Address Map (静态描述)
              ├── Handler 1: ROM (0x0000-0x1FFF)
              ├── Handler 2: RAM (0x2000-0x3FFF)
              ├── Handler 3: I/O Port (0x8000-0x8007)
              ├── Handler 4: Memory Bank (0x4000-0x7FFF)
              └── Handler 5: Pass-through Tap (0x3000-0x3001)
```

### 2.2 关键概念

| 概念 | 说明 | 对应 Lua API |
|------|------|-------------|
| **Address Space** | CPU 可访问的地址总线 | `cpu.spaces["program"]` |
| **Address Map** | 静态地址映射描述 | `space.map.entries` |
| **Memory Bank** | 可切换的内存区域 | `memory.banks[tag]` |
| **Memory Region** | ROM 数据区域 | `memory.regions[tag]` |
| **Memory Share** | 共享内存（多 CPU 间） | `memory.shares[tag]` |
| **Handler** | 地址处理函数（读/写/映射） | `entry.read`, `entry.write` |
| **Tap** | 监听拦截（不改变映射） | `install_read_tap()` |

### 2.3 Tap 的工作原理（关键！）

```c
// MAME 源码中 Tap 的定义
using tap = std::function<void (offs_t offset, uNN &data, uNN mem_mask)>;

// 安装 Tap
memory_passthrough_handler mph = space.install_read_tap(
    addrstart, addrend, name, read_tap, &mph);

// 执行时：
// 1. CPU 发起读取请求
// 2. 地址解码，找到对应 Handler
// 3. 如果该地址有 Tap，先调用 Tap 回调
// 4. 回调可以修改 data 的值（返回新值）
// 5. 然后继续执行正常的 Handler
```

**关键发现**：
- **Write Tap**：在写入**之前**调用，可以修改要写入的值
- **Read Tap**：在读取**之后**调用，可以修改返回的值
- **Tap 不覆盖 Handler**：Tap 是监听器，不是替换器
- **多个 Tap 可以共存**：但最后一个安装的优先级最高
- **Tap 在回调中禁止 I/O**：不能调用 print、io.open、log 等（会静默禁用）

### 2.4 地址映射的动态性

**重要**：MAME 的地址映射可以**动态变化**！

```lua
-- 监听地址空间变化
space:add_change_notifier(function(change_type)
  -- change_type: 'r' (read handlers changed), 'w' (write), 'rw' (both)
  -- 当 Bank 切换或 Handler 改变时触发
end)
```

**应用场景**：NeoGeo 的 BANK 切换、CPS1 的内存分页等。如果游戏动态切换了内存 Bank，之前安装的 Tap 可能需要 reinstall。

---

## 三、MAME 状态管理机制

### 3.1 设备状态层级

```
System Driver
  ├── Machine (running_machine)
  │     ├── Devices (tree)
  │     │     ├── :maincpu (CPU)
  │     │     │     ├── state (寄存器: D0, D1, PC, etc.)
  │     │     │     ├── spaces (地址空间)
  │     │     │     └── memory (内存映射)
  │     │     ├── :audiocpu (音频 CPU)
  │     │     ├── :screen (显示设备)
  │     │     └── :... (其他设备)
  │     ├── memory (内存管理器)
  │     │     ├── shares (共享内存)
  │     │     ├── banks (内存 Bank)
  │     │     └── regions (ROM 区域)
  │     └── ioport (输入端口)
  └── Save State (序列化的状态)
```

### 3.2 寄存器 vs 内存 vs 状态项

| 类型 | 访问方式 | 说明 |
|------|----------|------|
| **CPU 寄存器** | `cpu.state["D0"].value` | CPU 内部寄存器 |
| **内存地址** | `mem:read_u8(addr)` | 地址空间中的数据 |
| **设备状态** | `device.state_entries` | 设备特定的状态变量 |
| **输入端口** | `ioport.ports[tag].fields` | 控制器输入状态 |

### 3.3 Save State 机制

MAME 的 Save State 是**完整的状态快照**，包括：
- 所有 CPU 寄存器
- 所有内存内容
- 所有设备状态
- 定时器状态

**Lua 中的应用**：
- 可以通过 `machine:save()` / `machine:load()` 保存/加载状态
- 在特定阶段（如 CHALLENGER 倒计时前）保存状态，反复测试
- 这比手动重启快得多

---

## 四、Lua 脚本执行时机与限制

### 4.1 三种使用方式

| 方式 | 触发时机 | 适用场景 |
|------|----------|----------|
| `-console` | 交互式 | 调试、探索 |
| `-autoboot_script` | 启动后 delay | 自动化测试 |
| **Plugin** | 系统加载时 | **生产环境（LuaFighter 使用）** |

### 4.2 事件钩子执行顺序

```
一帧内的事件顺序：

1. CPU 执行 (多个 CPU 时间切片)
2. 定时器到期处理
3. 视频更新 (video_update)
4. → register_video_update 回调
5. 帧绘制完成
6. → register_frame_done 回调
7. → register_periodic 回调
8. throttle 等待（控制帧率）
```

**关键理解**：
- `register_periodic` 在**视频更新之后**执行
- 这意味着 Lua 读取的内存值是**该帧 CPU 执行完毕后的最终状态**
- 但 Lua 的输入修改要到**下一帧**才会被 CPU 读取

### 4.3 输入注入的延迟问题

```
Frame N:   Lua 读取内存 → 计算 → 设置输入 (Tap 或 field:set_value)
Frame N+1: CPU 读取输入 → 更新游戏状态
Frame N+2: Lua 看到更新后的状态
```

**关键发现**：
- 通过 `install_read_tap` 注入输入有**1 帧延迟**（因为 Tap 在 CPU 读取时触发）
- 通过 `field:set_value` 也有**1 帧延迟**（因为 IOPort 在 CPU 读取前采样）
- 如果 Lua 的 `register_periodic` 在视频更新后执行，那输入设置到 CPU 读取有**1 帧**间隔

---

## 五、当前 LuaFighter 架构问题分析

### 5.1 问题 1：Lua 执行时序理解错误

**当前代码**：
```lua
emu.register_periodic(function()
  -- 读取内存
  -- 计算 AI
  -- 设置输入
end)
```

**问题**：`register_periodic` 在视频更新后执行，但此时 CPU 已经执行完毕。输入设置要到**下一帧** CPU 执行时才会生效。

**改进方案**：如果需要更及时的响应，考虑使用 `register_frame`（在视频更新前执行）。

### 5.2 问题 2：Tap 回调中的 I/O 操作

**已知**：在 `install_read_tap` 回调中**绝对禁止** print / io.open / log 等 I/O 操作。

**当前代码**：`input-controller.lua` 中的 NeoGeo Tap 回调包含日志输出：
```lua
function(offset, data, mask)
  if offset == 0x300000 then
    return (data & 0xFF00) | NEOGEO_TAP_STATE.p1
  end
  return data
end
```

**问题**：虽然当前回调没有 I/O 操作，但如果未来添加日志，会导致 Tap 被静默禁用。

**改进方案**：将状态更新与日志分离，Tap 回调只返回数据，日志在 `register_periodic` 中输出。

### 5.3 问题 3：内存读取类型不匹配

**当前代码**：
```lua
function readXCoord(addr)
  local val = mem:readU32(addr) or 0
  if val > 0xFFFF then val = val & 0xFFFF end
  return val
end
```

**问题**：
1. `readU32` 读取的是**大端序**（MAME 的 68000 是大端）
2. 如果地址只存储了 16 位值，readU32 会读取相邻地址的数据
3. 这可能导致坐标值包含了其他数据（如 Y 坐标的高位）

**改进方案**：
- 先确认地址实际存储的数据宽度（通过 Cheat Database 或调试器）
- 使用匹配的读取函数（readU8 / readU16 / readU32）
- 对于 KOF97，Cheat Database 显示血量是 Byte（pb），坐标需要验证

### 5.4 问题 4：状态检测不精确

**当前代码**：
```lua
function isControllable(player)
  local state = self:_readState(player)
  if state == nil then return true end
  if hitState and hitState ~= 0 then return false end
  local okStates = self.config.controllableStates or DEFAULT_CONTROLLABLE_STATES
  for _, s in ipairs(okStates) do
    if state == s then return true end
  end
  return false
end
```

**问题**：
1. 状态值可能是**复合值**（低字节 = 基本状态，高字节 = 附加标志）
2. 可控性判断过于简单，没有考虑：
   - 投技动画中（不可控）
   - 超必杀动画中（不可控）
   - 倒地/起身过程中（不可控）
   - 格挡硬直中（部分可控）

**改进方案**：
- 使用**多条件**判断：状态 + 受击状态 + 动画标志 + 硬直计数器
- 或者使用**白名单**方式：只判断明确不可控的状态

### 5.5 问题 5：输入持久化机制问题

**当前代码**：
```lua
function InputController:setDirection(player, direction)
  -- 先释放所有方向键
  for _, dir in ipairs({"UP", "DOWN", "LEFT", "RIGHT"}) do
    local portName = map[dir]
    if portName then
      self:clearPersistent(portName)  -- 释放
    end
  end
  -- 然后设置新方向
  for _, dir in ipairs(dirs) do
    local portName = map[dir]
    if portName then
      self:setPersistent(portName)  -- 按下
    end
  end
end
```

**问题**：
1. 每帧都释放+按下，会产生**抖动**
2. 如果方向键只需要保持按下，不需要每帧重新设置
3. 对于 NeoGeo 的 `setPersistent`，会持续按住，但释放操作可能导致 1 帧的松开

**改进方案**：
- 缓存上一帧的方向状态，只在方向变化时操作
- 使用**差分更新**：只修改变化的键，不全部释放再按下

### 5.6 问题 6：AI 执行频率与游戏逻辑不同步

**当前代码**：
```lua
local AI_CYCLE_FRAMES = 60

function FtgAiArena:updateFrame(frameCount)
  self.aiTimer = self.aiTimer + 1
  local phase = self.aiTimer % AI_CYCLE_FRAMES
  -- 根据 phase 决定行为
end
```

**问题**：
1. AI 每 60 帧才做一次决策，但格斗游戏需要**每帧**响应
2. 这导致角色反应迟钝，错过攻击时机
3. 连招输入需要精确的帧级时序，60 帧周期太粗糙

**改进方案**：
- 将 AI 决策分为**高频层**（每帧：方向调整、防御判断）和**低频层**（每 30-60 帧：策略切换、连招选择）
- 连招输入需要**帧级精确**的序列控制

### 5.7 问题 7：Phase 检测的滞后性

**当前代码**：使用 `phaseHistory` 多数表决 + 3 帧平滑窗口。

**问题**：
- 从 SELECT 切换到 FIGHT 需要 3 帧确认（约 50ms）
- 格斗游戏中，50ms 可能错过最佳攻击时机
- 使用 fastSwitch 但只在状态字节明确变化时触发

**改进方案**：
- 使用更精确的状态触发（如血量初始化 + 时间开始倒计时）
- 减少平滑窗口到 1 帧（或直接响应）
- 考虑使用 `savestate` 快速回滚到已知状态

---

## 六、系统性改进方案

### 6.1 架构改进：三层控制系统

```
┌─────────────────────────────────────┐
│  Layer 3: 策略层 (Strategy)          │ 每 60-120 帧
│  - 选择整体策略（进攻/防守/消耗）      │
│  - 根据血量差决定是否拼命               │
│  - 选择连招类型                        │
└─────────────────────────────────────┘
           ↓
┌─────────────────────────────────────┐
│  Layer 2: 战术层 (Tactical)          │ 每 6-12 帧
│  - 距离判断（近/中/远）                │
│  - 是否进入攻击范围                    │
│  - 防御/反击判断                      │
│  - 起跳/蹲下决策                      │
└─────────────────────────────────────┘
           ↓
┌─────────────────────────────────────┐
│  Layer 1: 执行层 (Execution)          │ 每帧
│  - 方向调整（靠近/远离/起跳/蹲下）    │
│  - 攻击按钮按下/释放                  │
│  - 连招序列帧级控制                   │
│  - 防御（拉后/格挡）                  │
└─────────────────────────────────────┘
```

### 6.2 输入控制改进：状态机 + 差分更新

```lua
-- 输入状态机
local InputStateMachine = {}

function InputStateMachine:new()
  return {
    currentState = {},  -- 当前各键状态
    lastState = {},     -- 上一帧状态
    comboQueue = {},    -- 连招序列
    comboFrame = 0,     -- 连招当前帧
  }
end

function InputStateMachine:update(inputCtrl, player)
  -- 差分更新：只修改变化的键
  for button, state in pairs(self.currentState) do
    if self.lastState[button] ~= state then
      if state then
        inputCtrl:setPersistent(button, player)
      else
        inputCtrl:clearPersistent(button, player)
      end
      self.lastState[button] = state
    end
  end
end
```

### 6.3 内存读取改进：类型安全 + 缓存

```lua
-- 带类型校验的内存读取
local MemoryReader = {}

function MemoryReader:new(mem)
  return {
    mem = mem,
    cache = {},       -- 值缓存（每帧清空）
    addrConfig = {},  -- 地址配置（类型、宽度）
  }
end

function MemoryReader:register(addr, type, width)
  self.addrConfig[addr] = { type = type, width = width }
end

function MemoryReader:read(addr)
  if self.cache[addr] ~= nil then
    return self.cache[addr]  -- 返回缓存值
  end
  
  local config = self.addrConfig[addr]
  if not config then
    error("Unknown address: " .. tostring(addr))
  end
  
  local value
  if config.width == 8 then
    value = self.mem:read_u8(addr)
  elseif config.width == 16 then
    value = self.mem:read_u16(addr)
  elseif config.width == 32 then
    value = self.mem:read_u32(addr)
  end
  
  self.cache[addr] = value
  return value
end

function MemoryReader:flush()
  self.cache = {}  -- 每帧清空缓存
end
```

### 6.4 状态检测改进：多维度判断

```lua
-- 可控性判断：多维度
function isControllable(player)
  local state = readState(player)        -- 基本状态
  local hitState = readHitState(player)   -- 受击状态
  local animFlag = readAnimFlag(player)   -- 动画标志
  local stunTimer = readStunTimer(player) -- 硬直计时器
  
  -- 明确不可控的情况
  if hitState ~= 0 then return false end        -- 受击中
  if stunTimer > 0 then return false end        -- 硬直中
  if animFlag & BLOCK_STUN ~= 0 then            -- 格挡硬直
    return stunTimer <= 0
  end
  
  -- 基本状态判断
  if state == nil then return true end
  return state == 0 or state == 1 or state == 2 or state == 3
end
```

### 6.5 Phase 检测改进：精确触发

```lua
-- 使用 Save State 快速回滚测试
local function detectPhaseFast()
  -- 1. 检查时间地址是否开始倒计时
  local time = readTime()
  if time > 0 and time <= 99 then
    -- 2. 检查血量是否初始化
    local hp1, hp2 = readHealth()
    if hp1 > 0 and hp2 > 0 then
      return PHASE.FIGHT
    end
  end
  
  -- 3. 检查状态字节
  local state = readStateByte()
  if state == sv.fight then
    return PHASE.FIGHT
  end
  
  return PHASE.UNKNOWN
end
```

---

## 七、实施路线图

### Phase 1：地址验证（已完成）
- ✅ 发现 KOF97 血量地址偏移 1 字节
- ✅ 确认 Cheat Database 作为验证来源
- ⏳ 验证坐标/状态/朝向地址（需要调试器）

### Phase 2：输入控制重构（下一步）
- 实现差分更新机制（只修改变化的键）
- 分离 Tap 回调与日志输出
- 添加输入状态机缓存

### Phase 3：AI 架构重构
- 实现三层控制系统（策略/战术/执行）
- 连招序列帧级精确控制
- 可控性判断多维度化

### Phase 4：Phase 检测优化
- 减少平滑窗口到 1 帧
- 使用 Save State 快速回滚测试
- 实现更精确的战斗触发检测

### Phase 5：通用化工具
- 编写 Lua 内存扫描脚本（自动发现地址）
- 解析 Cheat Database 自动生成 ROM 配置
- 建立地址验证框架（读取→修改→验证）

---

## 八、参考资料

1. MAME Lua 文档：https://docs.mamedev.org/luascript/index.html
2. MAME 内存系统：https://docs.mamedev.org/techspecs/memory.html
3. MAME CPU 设备：https://docs.mamedev.org/techspecs/cpu_device.html
4. Aaron Giles 的 MAME 历史：https://aarongiles.com/old/mamemem/
5. MAME Cheat Database：https://www.mamecheat.co.uk/
6. Lua Memory System API：https://docs.mamedev.org/luascript/ref-mem.html

---

*报告状态：v1.0 - 已完成系统性分析，等待实施*
