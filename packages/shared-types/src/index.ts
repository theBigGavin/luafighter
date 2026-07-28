// ============================
// 共享类型定义 - @luafighter/shared-types
// ============================

// -----------------------------------
// 行情数据类型
// -----------------------------------

export interface MarketTick {
  symbol: string;
  timestamp: number;
  bidVolume: number;      // 主动买入量
  askVolume: number;      // 主动卖出量
  bidAmount: number;      // 多方成交额
  askAmount: number;      // 空方成交额
  strengthIndex: number;  // 归一化多方力量 -1.0 ~ 1.0
}

export interface MarketStrength {
  symbol: string;
  strengthIndex: number;  // -1.0 (空方绝对优势) ~ 1.0 (多方绝对优势)
  bidAmountTotal: number;
  askAmountTotal: number;
  bidVolumeTotal: number;
  askVolumeTotal: number;
  diffRatio: number;      // (bid - ask) / (bid + ask)
  lastPrice: number;      // 最新成交价
  priceChange: number;    // 较上一 tick 涨跌额
  timestamp: number;      // tick 时间戳
}

// -----------------------------------
// 游戏状态类型
// -----------------------------------

export type GamePhase =
  | 'attract'      // 吸引画面/标题
  | 'select'       // 选人画面
  | 'loading'      // 加载中
  | 'round_start'  // Round 开始
  | 'fighting'     // 对战中
  | 'round_end'    // Round 结束
  | 'game_end'     // 对局结束
  | 'unknown';

export interface FighterState {
  player: 1 | 2;
  health: number;         // 当前血量 (0 ~ max)
  maxHealth: number;
  x: number;                // X 坐标
  y: number;                // Y 坐标
  isStunned: boolean;       // 是否硬直
  isBlocking: boolean;      // 是否防御中
  isAirborne: boolean;      // 是否在空中
}

export interface RoundState {
  round: number;            // 当前第几 Round (1, 2, 3...)
  p1: FighterState;
  p2: FighterState;
  timeRemaining: number;    // 倒计时秒数
}

export interface MatchScore {
  p1Wins: number;
  p2Wins: number;
  totalRounds: number;
  bestOf: number;          // 三局两胜 = 3
}

export interface GameState {
  roomId: string;
  rom: string;
  phase: GamePhase;
  round: RoundState | null;
  score: MatchScore;
  marketData: MarketStrength | null;
}

// -----------------------------------
// 指令协议 (Node.js → Lua)
// -----------------------------------

export interface MoveTendency {
  forward: number;   // 0 ~ 1
  backward: number;
  jump: number;
  crouch: number;
  neutral: number;
}

export interface StrategyCommand {
  command: 'set_strategy';
  player: 1 | 2;
  action: 'aggressive' | 'defensive' | 'neutral';
  moveTendency: MoveTendency;
  specialMove?: string;   // 可选: 强制出特定招式
}

export interface InputCommand {
  command: 'input';
  player: 1 | 2;
  buttons: string[];      // 如 ['P1_LEFT', 'P1_BUTTON1']
  duration: number;       // 持续帧数
}

export interface ComboCommand {
  command: 'combo';
  player: 1 | 2;
  sequence: Array<{ buttons: string[]; duration: number; delay: number }>;
}

export type LuaCommand = StrategyCommand | InputCommand | ComboCommand;

/**
 * 传输信封：LuaBridge 在发送时为每条命令附加递增 seq，
 * Lua 端处理完毕后回 { event: 'ack', seq }，Node 端超时未收到 ack 则重发。
 */
export interface LuaCommandEnvelope {
  seq?: number;
}

export interface LuaAckEvent {
  event: 'ack';
  seq: number;
}

// -----------------------------------
// 事件上报 (Lua → Node.js)
// -----------------------------------

export interface LuaEventBase {
  event: string;
  roomId: string;
}

export interface LuaReadyEvent extends LuaEventBase {
  event: 'ready';
  rom: string;
}

export interface LuaStateUpdateEvent extends LuaEventBase {
  event: 'update';
  p1Hp: number;
  p2Hp: number;
  p1X: number;
  p2X: number;
  gameState: number;   // 原始内存状态值
}

export interface LuaRoundEndEvent extends LuaEventBase {
  event: 'round_end';
  winner: 1 | 2;
  p1Health: number;
  p2Health: number;
  round: number;
}

export interface LuaGameEndEvent extends LuaEventBase {
  event: 'game_end';
  winner: 1 | 2;
  p1Wins: number;
  p2Wins: number;
}

export interface LuaPhaseChangeEvent extends LuaEventBase {
  event: 'phase_change';
  phase: GamePhase;
  detail?: string;
}

export type LuaEvent =
  | LuaReadyEvent
  | LuaStateUpdateEvent
  | LuaRoundEndEvent
  | LuaGameEndEvent
  | LuaPhaseChangeEvent;

// -----------------------------------
// 房间/对局管理类型
// -----------------------------------

export interface RoomConfig {
  roomId: string;
  rom: string;
  symbol: string;        // 绑定的行情代码
  display: string;        // Xvfb display, 如 :99
  streamId: string;       // 推流ID
  metadata?: RomMetadata; // ROM 支持级别元数据（由 match-manager 加载后注入）
  bios?: string;          // 可选：MAME BIOS 名称（如 unibios40）
}

export interface RoomStatus {
  roomId: string;
  status: 'idle' | 'initializing' | 'running' | 'crashed' | 'stopped';
  rom: string;
  symbol: string;
  supportTier?: RomSupportTier;
  controlMode?: RomControlMode;
  gameState: GameState | null;
  uptime: number;
}

// -----------------------------------
// ROM 配置类型
// -----------------------------------

export interface RomConfig {
  rom: string;            // ROM 名称, 如 sf2ce
  name: string;           // 显示名称
  platform?: string;      // 平台: cps1 | neogeo
  metadata: RomMetadata;  // ROM 支持级别与控制目标
  stateAddress: string;   // 游戏状态地址 (hex string)
  stateValues: {
    attract?: number;
    title?: number;
    select?: number;
    loading?: number;
    fight?: number;
    ko?: number;
    win?: number;
  };
  p1HealthAddr: string;
  p2HealthAddr: string;
  p1XAddr: string;
  p2XAddr: string;
  p1YAddr?: string;
  p2YAddr?: string;
  timeAddr?: string | null;
  p1StateAddr?: string | null;
  p2StateAddr?: string | null;
  p1PowerAddr?: string | null;
  p2PowerAddr?: string | null;
  maxHealth: number;
  attackDistance?: number; // AI 开始攻击的距离阈值（内部坐标单位）
  lockTime?: boolean;
  lockPower?: boolean;
  lockHealth?: boolean;
  lockTimeValue?: number | null;
  lockPowerValue?: number | null;
  controllableStates?: number[];
  force2P?: boolean;
  p1InputMap: Record<string, string>;  // logical -> MAME port name
  p2InputMap: Record<string, string>;
  characters: string[];   // 可选角色列表
  selectConfig: {
    p1CursorStartX: number;
    p1CursorStartY: number;
    p2CursorStartX: number;
    p2CursorStartY: number;
    confirmButton: string;
    moveDelayFrames: number;
  };
  combos: Record<string, Array<{ buttons: string[]; duration: number; delay: number }>>;
  neogeoInputPorts?: {
    coin: string;
    start: string;
    p1: string;
    p2: string;
  };
  neogeoFieldMasks?: Record<string, number>;
  addressMeta?: Record<string, RomAddressMeta>;
}

// -----------------------------------
// 推流类型
// -----------------------------------

export interface StreamInfo {
  streamId: string;
  roomId: string;
  rtmpUrl: string;
  webrtcUrl: string;
  status: 'idle' | 'streaming' | 'error';
}

// -----------------------------------
// 常量
// -----------------------------------

export const MARKET_WS_PORT = 9001;
export const MANAGER_WS_PORT = 9002;
export const MANAGER_HTTP_PORT = 9003;
export const MANAGER_SOCKET_IO_PORT = 9004;
export const MEDIA_HTTP_PORT = 9005;
export const LUA_WS_PORT_BASE = 10000;  // 每个 MAME 实例分配一个端口

export const DEFAULT_SYMBOL = 'IF2306';
export const DEFAULT_ROM = 'kof97';

// -----------------------------------
// ROM 支持级别与元数据
// -----------------------------------

export type RomSupportTier =
  | 'stable'            // 已验证，可作为主流程 ROM
  | 'stable_candidate'  // 主验证 ROM，目标进入 stable
  | 'experimental'      // 仅用于实验、校准或限制验证
  | 'unsupported';      // 已知不可控

export type RomControlMode =
  | 'dual_control_target'   // 目标：1P/2P 均可被外部策略控制
  | 'single_control_target' // 仅 1P 可控
  | 'input_experiment_only' // 仅验证输入注入、地址或阶段识别
  | 'uncontrollable';       // 无法控制

export type RomCalibrationStatus =
  | 'verified'
  | 'partial'
  | 'unverified'
  | 'unknown';

export type RomPhaseConfidence =
  | 'high'
  | 'medium'
  | 'low'
  | 'untrusted';

export interface RomAddressMeta {
  source?: string;            // 来源：cheat xml / debugger / 校准文档
  verifiedAt?: string;        // ISO 日期
  confidence?: RomCalibrationStatus;
  note?: string;
}

export interface RomMetadata {
  supportTier: RomSupportTier;
  controlMode: RomControlMode;
  phaseConfidence: RomPhaseConfidence;
  calibrationStatus: RomCalibrationStatus;
  knownLimitations: string[];
}
