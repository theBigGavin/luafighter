# KOF97 校准与部署笔记

> **2026-07-28 更正**：本文档早期结论已部分过时。输入链路修复后实测：
> - **应使用 stock BIOS，不要用 unibios40**——持续按键脉冲会在 UniBIOS 启动画面触发其内置作弊菜单（A+B+C），且 stock BIOS 下投币/Start/选人/对战全流程已验证可用。
> - NeoGeo 输入只走 `field:set_value`（效果仅一帧，需每帧重注）；read-tap 与 set_value 双轨会互相抵消，默认关闭。
> - `p2XAddr` 已用内存 diff 探针校正为 `0x108422`（本文档的 `0x108502` 实测全程无变化）。
>
> 以下内容为历史记录，地址表以 `lua-scripts/rom-configs/kof97.json` 为准。

## 运行要求

- MAME 0.288（linuxserver/mame 镜像已内置）
- ROM：`kof97.zip`（Japan/Europe 版本，NGM-2320）
- BIOS：`neogeo.zip` 中必须包含 **Universe BIOS 4.0**（`uni-bios_4_0.rom`）
- 启动参数：`-bios unibios40`

> 默认 MVS/Asia BIOS 在 title 画面不会响应自动化 `Start` 输入，导致无法进入 1P vs 2P。Universe BIOS 可直接进入 VS 选人/排序画面，是目前稳定进场的关键。

## 已验证内存地址

| 字段 | 地址 | 说明 |
|------|------|------|
| P1 血量 | `0x108239` | 满血 103（0x67） |
| P2 血量 | `0x108439` | 满血 103（0x67） |
| P1 X 坐标 | `0x108302` | 有符号 16-bit，战斗初始约 24592 |
| P2 X 坐标 | `0x108502` | 有符号 16-bit，战斗初始约 18156 |
| 对战时间 | `0x10A83A` | 96 开始递减；**写入会触发 WORK RAM ERROR** |
| 游戏状态 | `0x10A5F4` | Neo Geo BIOS game state byte：0=attract, 1=title, 4=select, 8=fight, 10=ko, 11=win |
| 对战模式 1 | `0x10A84A` | 需写入 0x10（3v3） |
| 对战模式 2 | `0x10A859` | 需写入 0x10（3v3） |

> 注意：KOF97 的 `stateAddress` 在战斗期间可能保持 0，因此阶段检测以 **时间 + 血量** 为主，`stateAddress` 仅作辅助。

## 关键配置项

```json
{
  "lockHealth": false,
  "lockTime": false,
  "lockPower": false,
  "force2P": true,
  "battleModeValue": 16,
  "bios": "unibios40"
}
```

- `lockHealth`/`lockTime`/`lockPower` 必须设为 `false`：对 KOF97 的这些地址写入会触发 `WORK RAM ERROR`。
- `force2P` 与 `battleModeValue` 由进场状态机使用，用于确认 VS 模式。
- `bios` 由 `mame-pool.ts` 透传给 MAME 启动参数。

## 进场状态机

实现：`lua-scripts/drivers/entry-kof97.lua`

序列：

1. 等待 300 帧让 Universe BIOS 稳定。
2. 同时给 P1/P2 投币（`AUDIO_COIN` 端口）。
3. P1 Start 进入角色选择。
4. P2 Start 加入 2P VS 模式。
5. 持续按 P1/P2 的 A 键完成自动选人和确认。
6. 检测到 `time > 0 && hp1 > 0 && hp2 > 0` 即视为进入对战。

## Docker 插件加载注意事项

MAME 0.288 的插件发现机制要求自定义插件与官方系统插件位于同一根目录（该目录需包含 `boot.lua`、`plugin.schema` 等）。仅通过 `-pluginspath /app/plugins` 指向自定义目录会导致插件无法加载。

解决方案：

- 启动脚本 `scripts/docker-entry-match-manager.sh` 在容器启动时将 `/usr/share/games/mame/plugins` 复制到 `/tmp/mame-plugins`，再把 `/app/plugins` 覆盖进去。
- `mame-pool.ts` 通过环境变量 `PLUGIN_PATH=/tmp/mame-plugins` 将该合并目录传给 MAME。
- `LUAFIGHTER_PATH=/app` 保证 `init.lua` 能解析到 `/app/lua-scripts`。

## 行情驱动必杀技

`packages/match-manager/src/decision-engine.ts` 针对 KOF97 选择：

- P1 aggressive → `power_wave`
- P2 aggressive → `rising_tackle`

对应按键序列见 `lua-scripts/rom-configs/kof97.json` 的 `combos` 字段。

## 已知限制

- `p1StateAddr` / `p2StateAddr` / `p1PowerAddr` / `p2PowerAddr` 尚未校准，AI 可控性判断目前默认放行。
- 阶段检测在 Universe BIOS 下主要依赖 `time+hp`，`stateAddress` 战斗期间为 0。
- 血量读取偶发抖动，KO 判定已加入“进入对战 60 帧后 + 连续 6 帧血量归零”的防抖逻辑。
