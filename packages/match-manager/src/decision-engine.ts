import {
  MarketStrength,
  StrategyCommand,
  MoveTendency,
  LuaEvent,
  LuaStateUpdateEvent,
} from '@luafighter/shared-types';

/**
 * 决策引擎
 * 根据行情多空强度生成游戏策略指令
 */

export interface DecisionConfig {
  aggressiveThreshold: number;    // 进攻阈值，默认 0.3
  defensiveThreshold: number;     // 防御阈值（负值），默认 -0.3
  minDistance: number;            // 最小距离，低于此强制后退（防止贴脸无限连）
  maxDistance: number;            // 最大距离，高于此强制接近
  randomFactor: number;           // 随机因子，0~1
}

export class DecisionEngine {
  private config: DecisionConfig;
  private lastStrength: number = 0;
  private smoothedStrength: number = 0;
  private strengthHistory: number[] = [];
  private historySize: number = 20;
  private rom: string;

  constructor(rom?: string, config?: Partial<DecisionConfig>) {
    this.rom = (rom || '').toLowerCase();
    this.config = {
      aggressiveThreshold: 0.3,
      defensiveThreshold: -0.3,
      minDistance: 30,
      maxDistance: 200,
      randomFactor: 0.15,
      ...config,
    };
  }

  private pickSpecial(forP1: boolean): string | undefined {
    if (this.rom.includes('kof97')) {
      return forP1 ? 'power_wave' : 'rising_tackle';
    }
    if (this.rom.includes('sf2')) {
      return 'hadoken';
    }
    return undefined;
  }

  /**
   * 核心决策：根据多空强度生成双方策略
   */
  decide(strength: MarketStrength, distance: number, p1Hp: number, p2Hp: number): {
    p1: StrategyCommand;
    p2: StrategyCommand;
  } {
    const si = strength.strengthIndex;
    this.updateHistory(si);
    this.smoothedStrength = this.calculateEMA(si);

    const s = this.smoothedStrength;
    const diff = strength.bidAmountTotal - strength.askAmountTotal;
    const total = strength.bidAmountTotal + strength.askAmountTotal;
    const diffRatio = total > 0 ? diff / total : 0;

    // 基础移动倾向
    let p1Forward = 0.5;
    let p1Backward = 0.2;
    let p2Forward = 0.5;
    let p2Backward = 0.2;

    // 根据多空强度调整
    if (s > this.config.aggressiveThreshold) {
      // 多方优势：1P 进攻，2P 防守
      p1Forward = 0.9;
      p1Backward = 0.05;
      p2Forward = 0.1;
      p2Backward = 0.8;
    } else if (s < this.config.defensiveThreshold) {
      // 空方优势：2P 进攻，1P 防守
      p1Forward = 0.1;
      p1Backward = 0.8;
      p2Forward = 0.9;
      p2Backward = 0.05;
    } else {
      // 僵持区域：双方均衡，偏向中距离牵制
      p1Forward = 0.5 + diffRatio * 0.3;
      p1Backward = 0.5 - diffRatio * 0.3;
      p2Forward = 0.5 - diffRatio * 0.3;
      p2Backward = 0.5 + diffRatio * 0.3;
    }

    // 强制接近约束：防止双方远离
    if (distance > this.config.maxDistance) {
      p1Forward = Math.max(p1Forward, 0.8);
      p2Forward = Math.max(p2Forward, 0.8);
    }

    // 随机因子
    const randomize = (v: number) => {
      const noise = (Math.random() - 0.5) * this.config.randomFactor;
      return Math.max(0, Math.min(1, v + noise));
    };

    // 血量劣势时的求生本能
    if (p1Hp < p2Hp * 0.5) {
      p1Backward = Math.max(p1Backward, 0.6); // 1P 血量劣势，增加后退
    }
    if (p2Hp < p1Hp * 0.5) {
      p2Backward = Math.max(p2Backward, 0.6); // 2P 血量劣势，增加后退
    }

    // 构建移动倾向
    const p1Tendency: MoveTendency = {
      forward: randomize(p1Forward),
      backward: randomize(p1Backward),
      jump: randomize(0.3 + (s > 0 ? 0.2 : 0)),
      crouch: randomize(0.2),
      neutral: randomize(0.1),
    };

    const p2Tendency: MoveTendency = {
      forward: randomize(p2Forward),
      backward: randomize(p2Backward),
      jump: randomize(0.3 + (s < 0 ? 0.2 : 0)),
      crouch: randomize(0.2),
      neutral: randomize(0.1),
    };

    // 动作风格
    const p1Action = s > this.config.aggressiveThreshold ? 'aggressive' : 
                     (s < this.config.defensiveThreshold ? 'defensive' : 'neutral');
    const p2Action = s < this.config.defensiveThreshold ? 'aggressive' : 
                     (s > this.config.aggressiveThreshold ? 'defensive' : 'neutral');

    // 可选特殊招式（根据 ROM 选择对应必杀技名称）
    // 当一方处于 aggressive 风格时，附带对应 ROM 的必杀技；Lua 侧有 90 帧冷却避免连发
    const p1Special = p1Action === 'aggressive' ? this.pickSpecial(true) : undefined;
    const p2Special = p2Action === 'aggressive' ? this.pickSpecial(false) : undefined;

    return {
      p1: {
        command: 'set_strategy',
        player: 1,
        action: p1Action as any,
        moveTendency: p1Tendency,
        specialMove: p1Special,
      },
      p2: {
        command: 'set_strategy',
        player: 2,
        action: p2Action as any,
        moveTendency: p2Tendency,
        specialMove: p2Special,
      },
    };
  }

  /**
   * 仅基于 Lua 上报的原始状态做紧急决策
   * 用于行情数据暂时缺失时的降级策略
   */
  fallbackDecide(distance: number, p1Hp: number, p2Hp: number): {
    p1: StrategyCommand;
    p2: StrategyCommand;
  } {
    const p1Advantage = p1Hp > p2Hp;
    
    return {
      p1: {
        command: 'set_strategy',
        player: 1,
        action: p1Advantage ? 'aggressive' : 'defensive',
        moveTendency: {
          forward: p1Advantage ? 0.8 : 0.3,
          backward: p1Advantage ? 0.1 : 0.7,
          jump: 0.3,
          crouch: 0.2,
          neutral: 0.1,
        },
      },
      p2: {
        command: 'set_strategy',
        player: 2,
        action: !p1Advantage ? 'aggressive' : 'defensive',
        moveTendency: {
          forward: !p1Advantage ? 0.8 : 0.3,
          backward: !p1Advantage ? 0.1 : 0.7,
          jump: 0.3,
          crouch: 0.2,
          neutral: 0.1,
        },
      },
    };
  }

  private updateHistory(value: number): void {
    this.strengthHistory.push(value);
    if (this.strengthHistory.length > this.historySize) {
      this.strengthHistory.shift();
    }
  }

  private calculateEMA(value: number): number {
    const alpha = 2 / (this.historySize + 1);
    if (this.strengthHistory.length === 0) return value;
    return alpha * value + (1 - alpha) * this.smoothedStrength;
  }
}
