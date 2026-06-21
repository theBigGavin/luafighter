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
  diffRatio: number;      // (bid - ask) / (bid + ask)
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
}

export interface RoomStatus {
  roomId: string;
  status: 'idle' | 'initializing' | 'running' | 'crashed' | 'stopped';
  rom: string;
  symbol: string;
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
  maxHealth: number;
  attackDistance?: number; // AI 开始攻击的距离阈值（内部坐标单位）
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
export const DEFAULT_ROM = 'sf2ce';
