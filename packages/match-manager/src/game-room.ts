import { EventEmitter } from 'events';
import {
  GameState,
  GamePhase,
  RoomConfig,
  RoomStatus,
  MarketStrength,
  FighterState,
  RoundState,
  MatchScore,
  MarketTick,
  LUA_WS_PORT_BASE,
} from '@luafighter/shared-types';
import { MameProcessManager, MamePool } from './mame-pool';
import { LuaBridge } from './lua-bridge';
import { DecisionEngine } from './decision-engine';

/**
 * 游戏房间
 * 管理单个对局的完整生命周期
 */

export class GameRoom extends EventEmitter {
  readonly config: RoomConfig;
  private luaBridge: LuaBridge | null = null;
  private decisionEngine: DecisionEngine;
  
  // 游戏状态
  private gameState: GameState;
  private currentStrength: MarketStrength | null = null;
  private lastStrategySend: number = 0;
  private strategyInterval: number = 500; // ms
  private lastUpdateTime: number = Date.now();
  
  // 状态机
  private status: RoomStatus['status'] = 'idle';
  private roundActive: boolean = false;
  private maxHealth: number = 144; // 与 Lua 端 ROM 配置保持一致
  private p1Hp: number = this.maxHealth;
  private p2Hp: number = this.maxHealth;
  private p1X: number = 100;
  private p2X: number = 300;
  private p1Wins: number = 0;
  private p2Wins: number = 0;
  private roundCount: number = 1;
  private maxRounds: number = 3;
  private winThreshold: number = 2;

  constructor(
    config: RoomConfig,
    private mamePool: MamePool,
    private mameManager?: MameProcessManager,
  ) {
    super();
    this.config = config;
    this.decisionEngine = new DecisionEngine();

    this.gameState = {
      roomId: config.roomId,
      rom: config.rom,
      phase: 'attract',
      round: null,
      score: { p1Wins: 0, p2Wins: 0, totalRounds: 0, bestOf: 3 },
      marketData: null,
    };
  }

  async start(): Promise<void> {
    if (this.status !== 'idle') {
      throw new Error('房间已在运行中');
    }

    this.status = 'initializing';
    console.log(`[Room ${this.config.roomId}] 开始初始化`);

    try {
      // 1. 启动 Lua 通信桥
      const displayNum = parseInt(this.config.display.replace(/\D/g, ''), 10);
      const wsPort = LUA_WS_PORT_BASE + displayNum;
      this.luaBridge = new LuaBridge(
        wsPort,
        this.config.roomId,
        {
          onReady: (rom) => this.onLuaReady(rom),
          onStateUpdate: (p1Hp, p2Hp, p1X, p2X) => this.onStateUpdate(p1Hp, p2Hp, p1X, p2X),
          onRoundEnd: (winner, round, p1Health, p2Health) => this.onRoundEnd(winner, round, p1Health, p2Health),
          onGameEnd: (winner, p1Wins, p2Wins) => this.onGameEnd(winner, p1Wins, p2Wins),
          onPhaseChange: (phase) => this.onPhaseChange(phase),
          onError: (error) => this.onLuaError(error),
        }
      );
      await this.luaBridge.start();

      // 2. 启动 MAME 进程（由外部 pool 创建后传入）
      // 注：实际 MAME 启动由 MamePool 完成，这里只需要等待连接
      
      this.status = 'running';
      this.lastUpdateTime = Date.now();
      console.log(`[Room ${this.config.roomId}] 初始化完成，等待 Lua 连接`);
      
    } catch (err) {
      this.status = 'crashed';
      console.error(`[Room ${this.config.roomId}] 初始化失败:`, err);
      throw err;
    }
  }

  stop(): Promise<void> {
    return new Promise(async (resolve) => {
      this.status = 'stopped';

      if (this.luaBridge) {
        await this.luaBridge.stop();
        this.luaBridge = null;
      }

      if (this.mameManager && this.mameManager.isRunning()) {
        await this.mameManager.stop();
        this.mameManager = undefined;
      }

      this.emit('stopped', this.config.roomId);
      resolve();
    });
  }

  /**
   * 接收行情数据更新
   */
  onMarketData(strength: MarketStrength): void {
    this.currentStrength = strength;
    this.gameState.marketData = strength;
    
    // 如果处于对战状态，发送策略
    if (this.roundActive && this.luaBridge?.getReady()) {
      this.sendStrategy();
    }
  }

  getStatus(): RoomStatus {
    return {
      roomId: this.config.roomId,
      status: this.status,
      rom: this.config.rom,
      symbol: this.config.symbol,
      gameState: this.gameState,
      uptime: Math.floor((Date.now() - this.lastUpdateTime) / 1000),
    };
  }

  getGameState(): GameState {
    return this.gameState;
  }

  private onLuaReady(rom: string): void {
    console.log(`[Room ${this.config.roomId}] Lua 就绪，ROM: ${rom}`);
    this.emit('ready', this.config.roomId);
  }

  private onStateUpdate(p1Hp: number, p2Hp: number, p1X: number, p2X: number): void {
    this.p1Hp = p1Hp;
    this.p2Hp = p2Hp;
    this.p1X = p1X;
    this.p2X = p2X;
    
    this.gameState.round = {
      round: this.roundCount,
      p1: {
        player: 1,
        health: p1Hp,
        maxHealth: this.maxHealth,
        x: p1X,
        y: 0,
        isStunned: false,
        isBlocking: false,
        isAirborne: false,
      },
      p2: {
        player: 2,
        health: p2Hp,
        maxHealth: this.maxHealth,
        x: p2X,
        y: 0,
        isStunned: false,
        isBlocking: false,
        isAirborne: false,
      },
      timeRemaining: 99, // 可由 Lua 上报
    };

    this.emit('stateUpdate', this.gameState);
  }

  private onRoundEnd(winner: 1 | 2, round: number, p1Health: number, p2Health: number): void {
    console.log(`[Room ${this.config.roomId}] Round ${round} 结束，胜者: P${winner}`);
    this.roundActive = false;
    
    if (winner === 1) this.p1Wins++;
    else this.p2Wins++;
    
    this.gameState.score = {
      p1Wins: this.p1Wins,
      p2Wins: this.p2Wins,
      totalRounds: this.roundCount,
      bestOf: this.maxRounds,
    };
    
    this.emit('roundEnd', { winner, round, p1Health, p2Health });
    
    // 检查是否分出胜负
    if (this.p1Wins < this.winThreshold && this.p2Wins < this.winThreshold) {
      this.roundCount++;
    }
  }

  private onGameEnd(winner: 1 | 2, p1Wins: number, p2Wins: number): void {
    console.log(`[Room ${this.config.roomId}] 对局结束，最终胜者: P${winner}`);
    this.roundActive = false;
    this.gameState.phase = 'game_end';
    this.gameState.score = { p1Wins, p2Wins, totalRounds: this.roundCount, bestOf: 3 };
    this.emit('gameEnd', { winner, p1Wins, p2Wins });
  }

  private onPhaseChange(phase: GamePhase): void {
    const normalized = normalizePhase(phase);
    this.gameState.phase = normalized;

    if (normalized === 'round_start' || normalized === 'fighting') {
      this.roundActive = true;
      // 确保前端在 phase 切换时能拿到正确的当前回合号
      if (this.gameState.round) {
        this.gameState.round.round = this.roundCount;
      } else {
        this.gameState.round = {
          round: this.roundCount,
          p1: { player: 1, health: this.p1Hp, maxHealth: this.maxHealth, x: this.p1X, y: 0, isStunned: false, isBlocking: false, isAirborne: false },
          p2: { player: 2, health: this.p2Hp, maxHealth: this.maxHealth, x: this.p2X, y: 0, isStunned: false, isBlocking: false, isAirborne: false },
          timeRemaining: 99,
        };
      }
      this.emit('stateUpdate', this.gameState);
    } else if (normalized === 'round_end' || normalized === 'game_end') {
      this.roundActive = false;
    }

    this.emit('phaseChange', normalized);
  }

  private onLuaError(error: string): void {
    console.error(`[Room ${this.config.roomId}] Lua 错误:`, error);
    this.emit('error', error);
  }

  /**
   * 将房间标记为崩溃（供外部健康检查调用）
   */
  markCrashed(): void {
    if (this.status === 'running' || this.status === 'initializing') {
      this.status = 'crashed';
      this.roundActive = false;
      console.error(`[Room ${this.config.roomId}] 进程异常，房间已标记为崩溃`);
      this.emit('crashed', this.config.roomId);
    }
  }

  private sendStrategy(): void {
    const now = Date.now();
    if (now - this.lastStrategySend < this.strategyInterval) return;
    this.lastStrategySend = now;

    const distance = Math.abs(this.p1X - this.p2X);

    let strategies: { p1: any; p2: any };

    if (this.currentStrength) {
      strategies = this.decisionEngine.decide(
        this.currentStrength,
        distance,
        this.p1Hp,
        this.p2Hp
      );
    } else {
      // 无行情数据时的降级策略
      strategies = this.decisionEngine.fallbackDecide(
        distance,
        this.p1Hp,
        this.p2Hp
      );
    }

    // 发送策略给 Lua
    if (this.luaBridge) {
      this.luaBridge.send(strategies.p1);
      this.luaBridge.send(strategies.p2);
    }
  }
}

function normalizePhase(phase: string): GamePhase {
  const map: Record<string, GamePhase> = {
    fight: 'fighting',
  };
  return (map[phase] || phase) as GamePhase;
}
