import { MarketTick, MarketStrength } from '@luafighter/shared-types';

/**
 * 多空强度计算器
 * 将原始 tick 数据转换为标准化的多空强度指标
 */

export interface StrengthResult {
  strength: MarketStrength;
  raw: {
    diff: number;
    total: number;
    ratio: number;
  };
}

export class StrengthCalculator {
  private windowSize: number;      // 滑动窗口大小（秒）
  private history: Map<string, MarketTick[]> = new Map();

  constructor(windowSize: number = 10) {
    this.windowSize = windowSize;
  }

  /**
   * 处理单个 tick，计算强度
   */
  calculate(tick: MarketTick): StrengthResult {
    const history = this.getHistory(tick.symbol);
    history.push(tick);

    // 清理过期数据
    const cutoff = tick.timestamp - this.windowSize;
    while (history.length > 0 && history[0].timestamp < cutoff) {
      history.shift();
    }

    // 滑动窗口聚合
    const totalBidAmount = history.reduce((sum, t) => sum + t.bidAmount, 0);
    const totalAskAmount = history.reduce((sum, t) => sum + t.askAmount, 0);
    const totalBidVol = history.reduce((sum, t) => sum + t.bidVolume, 0);
    const totalAskVol = history.reduce((sum, t) => sum + t.askVolume, 0);

    const diff = totalBidAmount - totalAskAmount;
    const total = totalBidAmount + totalAskAmount;

    // 归一化 strengthIndex: diff / (total * 0.5) -> [-1, 1]
    let strengthIndex = 0;
    if (total > 0) {
      strengthIndex = diff / (total * 0.5);
      strengthIndex = Math.max(-1, Math.min(1, strengthIndex));
    }

    // 成交量比率（辅助指标）
    const volDiff = totalBidVol - totalAskVol;
    const volTotal = totalBidVol + totalAskVol;
    let volRatio = 0;
    if (volTotal > 0) {
      volRatio = volDiff / volTotal;
    }

    // 综合强度：金额权重 80%，成交量权重 20%
    const composite = strengthIndex * 0.8 + volRatio * 0.2;
    const finalStrength = Math.max(-1, Math.min(1, composite));

    const marketStrength: MarketStrength = {
      symbol: tick.symbol,
      strengthIndex: parseFloat(finalStrength.toFixed(4)),
      bidAmountTotal: totalBidAmount,
      askAmountTotal: totalAskAmount,
      diffRatio: total > 0 ? parseFloat((diff / total).toFixed(4)) : 0,
    };

    return {
      strength: marketStrength,
      raw: { diff, total, ratio: total > 0 ? diff / total : 0 },
    };
  }

  /**
   * 获取多时间帧强度
   */
  calculateMultiTimeframe(tick: MarketTick): {
    short: StrengthResult;
    medium: StrengthResult;
    long: StrengthResult;
  } {
    const short = this.calculate(tick);

    // 临时切换窗口大小计算中长期
    const originalSize = this.windowSize;

    this.windowSize = 60;
    const medium = this.calculate(tick);

    this.windowSize = 300;
    const long = this.calculate(tick);

    this.windowSize = originalSize;

    return { short, medium, long };
  }

  private getHistory(symbol: string): MarketTick[] {
    if (!this.history.has(symbol)) {
      this.history.set(symbol, []);
    }
    return this.history.get(symbol)!;
  }

  clearHistory(symbol?: string): void {
    if (symbol) {
      this.history.delete(symbol);
    } else {
      this.history.clear();
    }
  }
}
