import { WebSocket } from 'ws';
import { MarketStrength } from '@luafighter/shared-types';

/**
 * 行情数据客户端
 * 连接行情数据服务的 WebSocket，接收实时数据并分发给各房间
 */

export interface MarketClientCallbacks {
  onTick: (strength: MarketStrength) => void;
  onConnect: () => void;
  onDisconnect: () => void;
  onError: (err: Error) => void;
}

export class MarketDataClient {
  private ws: WebSocket | null = null;
  private url: string;
  private symbols: string[];
  private callbacks: MarketClientCallbacks;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private reconnectInterval: number = 3000;
  private isConnected: boolean = false;
  private lastData: MarketStrength | null = null;

  constructor(url: string, symbols: string[], callbacks: MarketClientCallbacks) {
    this.url = url;
    this.symbols = symbols;
    this.callbacks = callbacks;
  }

  connect(): void {
    if (this.ws) return;

    console.log(`[MarketClient] 连接行情服务: ${this.url}`);
    
    try {
      this.ws = new WebSocket(this.url);

      this.ws.on('open', () => {
        console.log('[MarketClient] 已连接');
        this.isConnected = true;
        this.callbacks.onConnect();
        
        // 订阅 symbol
        this.ws?.send(JSON.stringify({
          type: 'subscribe',
          symbols: this.symbols,
        }));
      });

      this.ws.on('message', (data: Buffer) => {
        try {
          const msg = JSON.parse(data.toString());
          if (msg.type === 'tick' && msg.data) {
            this.lastData = msg.data.strength as MarketStrength;
            this.callbacks.onTick(this.lastData);
          }
        } catch (err) {
          console.error('[MarketClient] 数据解析失败:', err);
        }
      });

      this.ws.on('close', () => {
        console.log('[MarketClient] 连接断开');
        this.isConnected = false;
        this.callbacks.onDisconnect();
        this.scheduleReconnect();
      });

      this.ws.on('error', (err) => {
        console.error('[MarketClient] 连接错误:', err.message);
        this.callbacks.onError(err);
      });
    } catch (err) {
      console.error('[MarketClient] 创建连接失败:', err);
      this.scheduleReconnect();
    }
  }

  disconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }
    this.isConnected = false;
  }

  getLastData(): MarketStrength | null {
    return this.lastData;
  }

  getConnected(): boolean {
    return this.isConnected;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      console.log('[MarketClient] 尝试重连...');
      this.connect();
    }, this.reconnectInterval);
  }
}
