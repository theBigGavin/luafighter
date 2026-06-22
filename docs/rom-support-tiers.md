# LuaFighter ROM 支持级别

## 支持级别定义

| 级别 | 含义 | 用户可见行为 |
|------|------|-------------|
| `stable` | 已验证：可稳定自动进场、1P vs 2P 双边控制、行情驱动 AI | 前端显示“稳定”，默认推荐创建房间 |
| `experimental` | 实验性：内存地址/进场流程未完全校准，可能无法自动进场或只能单边控制 | 前端显示“实验”，创建房间时弹出警告 |
| `unsupported` | 不支持：缺少配置或已知无法运行 | 前端禁用选择 |

## 当前 ROM 状态

| ROM | 平台 | 级别 | 控制模式 | 关键说明 |
|-----|------|------|----------|----------|
| `kof97` | Neo Geo | `stable` | `dual_control` | 需要 **Universe BIOS**（`unibios40`）才能稳定进入 1P vs 2P；血量/时间/能量地址禁止写入，否则会触发 `WORK RAM ERROR` |
| `sf2ce` | CPS1 | `experimental` | `single_control` | 默认 MVS BIOS 下自动化无法完成 1P vs 2P 进场；仅作实验保留 |
| `sf2` | CPS1 | `experimental` | `single_control` | 同 `sf2ce` |

## 配置位置

- ROM 元数据：`lua-scripts/rom-configs/<rom>.json` 中的 `metadata.supportTier` 与 `metadata.controlMode`
- 共享类型：`packages/shared-types/src/index.ts` 中的 `RomSupportTier` / `ControlMode`
- 前端显示：`packages/frontend` 读取房间配置中的 `metadata` 字段展示徽章和警告

## 提升 ROM 级别的标准

一个 ROM 要从 `experimental` 提升到 `stable`，需要满足：

1. **自动进场**：无需人工干预即可从 attract/title 进入 1P vs 2P 对战。
2. **双边可控**： match-manager 能同时向 P1 和 P2 注入输入。
3. **状态可读**：血量、坐标、时间等核心地址稳定可读，且不会导致 MAME 报错/死机。
4. **行情联动**： decision-engine 能根据多空强度生成合理的动作风格，并映射到 ROM 对应的必杀技。
5. **连续运行**： 至少完成一整局（best-of-3）无明显误触发阶段切换或错误回合结束。
