import { MarketTick } from '@luafighter/shared-types';

/**
 * 数据源抽象接口
 */
export interface IDataSource {
  readonly name: string;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  subscribe(symbols: string[]): void;
  unsubscribe(symbols: string[]): void;
  onTick(callback: (tick: MarketTick) => void): void;
  offTick(callback: (tick: MarketTick) => void): void;
  isConnected(): boolean;
}

/**
 * 模拟数据源 - 用于本地测试和演示
 */
export class MockDataSource implements IDataSource {
  readonly name = 'MockDataSource';
  private connected = false;
  private tickCallbacks: Set<(tick: MarketTick) => void> = new Set();
  private interval: NodeJS.Timeout | null = null;
  private symbols: string[] = [];

  async connect(): Promise<void> {
    this.connected = true;
    console.log(`[${this.name}] 已连接`);
  }

  async disconnect(): Promise<void> {
    this.connected = false;
    if (this.interval) {
      clearInterval(this.interval);
      this.interval = null;
    }
    console.log(`[${this.name}] 已断开`);
  }

  subscribe(symbols: string[]): void {
    this.symbols = symbols;
    console.log(`[${this.name}] 订阅: ${symbols.join(', ')}`);
  }

  unsubscribe(symbols: string[]): void {
    this.symbols = this.symbols.filter((s) => !symbols.includes(s));
  }

  onTick(callback: (tick: MarketTick) => void): void {
    this.tickCallbacks.add(callback);
  }

  offTick(callback: (tick: MarketTick) => void): void {
    this.tickCallbacks.delete(callback);
  }

  isConnected(): boolean {
    return this.connected;
  }

  /**
   * 模拟数据源由外部 MockDataGenerator 驱动
   * 这里只是一个适配器壳
   */
  emit(tick: MarketTick): void {
    if (!this.connected) return;
    if (this.symbols.length > 0 && !this.symbols.includes(tick.symbol)) return;
    this.tickCallbacks.forEach((cb) => cb(tick));
  }
}

/**
 * 新浪数据源 - 预留接口，未来接入真实行情
 * TODO: 实现新浪 WebSocket 或 HTTP 轮询接口
 */
export class SinaDataSource implements IDataSource {
  readonly name = 'SinaDataSource';
  private connected = false;
  private tickCallbacks: Set<(tick: MarketTick) => void> = new Set();

  async connect(): Promise<void> {
    // TODO: 连接新浪 WebSocket 接口
    // 参考: wss://hq.sinajs.cn/... 或 HTTP 轮询
    throw new Error('新浪数据源尚未实现');
  }

  async disconnect(): Promise<void> {
    this.connected = false;
  }

  subscribe(symbols: string[]): void {
    // TODO: 发送订阅消息到新浪服务器
    console.log(`[${this.name}] 订阅: ${symbols.join(', ')}`);
  }

  unsubscribe(symbols: string[]): void {
    // TODO: 发送取消订阅消息
  }

  onTick(callback: (tick: MarketTick) => void): void {
    this.tickCallbacks.add(callback);
  }

  offTick(callback: (tick: MarketTick) => void): void {
    this.tickCallbacks.delete(callback);
  }

  isConnected(): boolean {
    return this.connected;
  }
}

/**
 * 东方财富数据源 - 预留接口
 * TODO: 接入东方财富 WebSocket 行情
 */
export class EastMoneyDataSource implements IDataSource {
  readonly name = 'EastMoneyDataSource';
  private connected = false;
  private tickCallbacks: Set<(tick: MarketTick) => void> = new Set();

  async connect(): Promise<void> {
    throw new Error('东方财富数据源尚未实现');
  }

  async disconnect(): Promise<void> {
    this.connected = false;
  }

  subscribe(symbols: string[]): void {
    console.log(`[${this.name}] 订阅: ${symbols.join(', ')}`);
  }

  unsubscribe(symbols: string[]): void {
    // TODO
  }

  onTick(callback: (tick: MarketTick) => void): void {
    this.tickCallbacks.add(callback);
  }

  offTick(callback: (tick: MarketTick) => void): void {
    this.tickCallbacks.delete(callback);
  }

  isConnected(): boolean {
    return this.connected;
  }
}
