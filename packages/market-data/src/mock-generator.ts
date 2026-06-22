import WebSocket from 'ws';
import { MarketTick, MarketStrength } from '@luafighter/shared-types';

/**
 * 行情数据生成器
 * 支持多种行情模式：bullish(多头), bearish(空头), volatile(震荡), ranging(盘整)
 */
export type MarketScenario = 'bullish' | 'bearish' | 'volatile' | 'ranging';

export interface GeneratorConfig {
  symbol: string;
  scenario: MarketScenario;
  intervalMs: number;      // 生成间隔
  drift: number;           // 趋势漂移量
  volatility: number;      // 波动率
}

export class MockDataGenerator {
  private configs: Map<string, GeneratorConfig> = new Map();
  private states: Map<string, {
    strength: number;
    bidAmount: number;
    askAmount: number;
    bidVol: number;
    askVol: number;
  }> = new Map();
  private timers: Map<string, NodeJS.Timeout> = new Map();
  private subscribers: Set<(tick: MarketTick) => void> = new Set();

  constructor() {
    // 默认配置
    this.register({
      symbol: 'IF2306',
      scenario: 'volatile',
      intervalMs: 500,
      drift: 0.02,
      volatility: 0.15,
    });
    this.register({
      symbol: 'IC2306',
      scenario: 'bullish',
      intervalMs: 500,
      drift: 0.05,
      volatility: 0.1,
    });
    this.register({
      symbol: '000001.SZ',
      scenario: 'ranging',
      intervalMs: 1000,
      drift: 0.01,
      volatility: 0.08,
    });
    this.register({
      symbol: 'BTCUSDT',
      scenario: 'volatile',
      intervalMs: 500,
      drift: 0.03,
      volatility: 0.25,
    });
  }

  register(config: GeneratorConfig): void {
    this.configs.set(config.symbol, config);
    this.states.set(config.symbol, {
      strength: 0,
      bidAmount: 1000000,
      askAmount: 1000000,
      bidVol: 1000,
      askVol: 1000,
    });
  }

  subscribe(callback: (tick: MarketTick) => void): void {
    this.subscribers.add(callback);
  }

  unsubscribe(callback: (tick: MarketTick) => void): void {
    this.subscribers.delete(callback);
  }

  start(symbol?: string): void {
    const symbols = symbol ? [symbol] : Array.from(this.configs.keys());
    for (const s of symbols) {
      if (this.timers.has(s)) continue;
      const cfg = this.configs.get(s)!;
      const timer = setInterval(() => {
        const tick = this.generateTick(s);
        this.subscribers.forEach((cb) => cb(tick));
      }, cfg.intervalMs);
      this.timers.set(s, timer);
      console.log(`[MockDataGenerator] 开始生成 ${s} 模拟数据，模式: ${cfg.scenario}`);
    }
  }

  stop(symbol?: string): void {
    if (symbol) {
      const timer = this.timers.get(symbol);
      if (timer) {
        clearInterval(timer);
        this.timers.delete(symbol);
        console.log(`[MockDataGenerator] 停止生成 ${symbol}`);
      }
    } else {
      for (const [s, timer] of this.timers) {
        clearInterval(timer);
        console.log(`[MockDataGenerator] 停止生成 ${s}`);
      }
      this.timers.clear();
    }
  }

  private generateTick(symbol: string): MarketTick {
    const cfg = this.configs.get(symbol)!;
    const state = this.states.get(symbol)!;

    // 随机游走 + 均值回归 + 场景漂移
    let noise = (Math.random() - 0.5) * cfg.volatility;
    let drift = cfg.drift;

    // 不同场景的处理
    switch (cfg.scenario) {
      case 'bullish':
        drift = Math.abs(drift) * 1.5;
        break;
      case 'bearish':
        drift = -Math.abs(drift) * 1.5;
        break;
      case 'volatile':
        noise *= 2.5;
        drift = Math.sin(Date.now() / 10000) * cfg.drift * 3;
        break;
      case 'ranging':
        drift = -state.strength * 0.03; // 均值回归
        noise *= 0.6;
        break;
    }

    let newStrength = state.strength + drift + noise;
    // 硬边界
    newStrength = Math.max(-0.95, Math.min(0.95, newStrength));
    // 软边界回归
    if (newStrength > 0.9) newStrength -= 0.01;
    if (newStrength < -0.9) newStrength += 0.01;

    state.strength = newStrength;

    // 根据 strength 生成 bid/ask 金额和量
    const baseAmount = 2000000;
    const baseVol = 2000;
    const ratio = (newStrength + 1) / 2; // 0 ~ 1

    state.bidAmount = baseAmount * (0.5 + ratio * 1.5) + Math.random() * 500000;
    state.askAmount = baseAmount * (0.5 + (1 - ratio) * 1.5) + Math.random() * 500000;
    state.bidVol = baseVol * (0.5 + ratio * 1.5) + Math.random() * 500;
    state.askVol = baseVol * (0.5 + (1 - ratio) * 1.5) + Math.random() * 500;

    return {
      symbol,
      timestamp: Math.floor(Date.now() / 1000),
      bidVolume: Math.floor(state.bidVol),
      askVolume: Math.floor(state.askVol),
      bidAmount: Math.floor(state.bidAmount),
      askAmount: Math.floor(state.askAmount),
      strengthIndex: parseFloat(newStrength.toFixed(4)),
    };
  }

  setScenario(symbol: string, scenario: MarketScenario): void {
    const cfg = this.configs.get(symbol);
    if (cfg) {
      cfg.scenario = scenario;
      console.log(`[MockDataGenerator] ${symbol} 场景切换为 ${scenario}`);
    }
  }

  getSymbols(): string[] {
    return Array.from(this.configs.keys());
  }
}
