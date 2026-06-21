import { WebSocketServer, WebSocket } from 'ws';
import fs from 'fs';
import {
  LuaEvent,
  LuaCommand,
  GameState,
  GamePhase,
  FighterState,
  RoundState,
  MatchScore,
} from '@luafighter/shared-types';

/**
 * Lua ↔ Node.js 通信桥
 * 每个房间对应一个 WebSocket 服务器，监听分配给该 MAME 实例的端口
 * 同时支持文件 I/O 轮询作为降级方案（当 MAME Lua 环境没有 luasocket 时）
 */

export interface LuaBridgeCallbacks {
  onReady: (rom: string) => void;
  onStateUpdate: (p1Hp: number, p2Hp: number, p1X: number, p2X: number) => void;
  onRoundEnd: (winner: 1 | 2, round: number, p1Health: number, p2Health: number) => void;
  onGameEnd: (winner: 1 | 2, p1Wins: number, p2Wins: number) => void;
  onPhaseChange: (phase: GamePhase) => void;
  onError: (error: string) => void;
}

export class LuaBridge {
  private wss: WebSocketServer | null = null;
  private ws: WebSocket | null = null;
  private port: number;
  private roomId: string;
  private callbacks: LuaBridgeCallbacks;
  private commandQueue: LuaCommand[] = [];
  private isReady: boolean = false;
  private checkInterval: NodeJS.Timeout | null = null;
  private filePollingActive: boolean = false;
  private pipeInPath: string;
  private pipeOutPath: string;

  constructor(port: number, roomId: string, callbacks: LuaBridgeCallbacks) {
    this.port = port;
    this.roomId = roomId;
    this.callbacks = callbacks;
    this.pipeInPath = `/tmp/luafighter_ipc_${roomId}_in`;
    this.pipeOutPath = `/tmp/luafighter_ipc_${roomId}_out`;
  }

  async start(): Promise<void> {
    // 预先创建管道文件，确保 Lua 端可以检测到
    this.ensurePipeFiles();

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        if (!this.isReady) {
          // WebSocket 未连接，降级到文件 I/O
          console.log(`[LuaBridge ${this.roomId}] WebSocket 未连接，降级到文件 I/O`);
          this.startFilePolling();
          this.isReady = true;
          resolve();
        }
      }, 10000);

      this.wss = new WebSocketServer({ port: this.port, host: '127.0.0.1' });

      this.wss.on('connection', (ws: WebSocket) => {
        console.log(`[LuaBridge ${this.roomId}] Lua 脚本已连接 (WebSocket)`);
        this.ws = ws;
        this.isReady = true;
        clearTimeout(timeout);
        this.stopFilePolling(); // 停止文件轮询
        resolve();

        ws.on('message', (data: Buffer) => {
          this.handleMessage(data.toString());
        });

        ws.on('close', () => {
          console.log(`[LuaBridge ${this.roomId}] Lua 连接断开，启动文件轮询`);
          this.ws = null;
          this.isReady = false;
          this.startFilePolling();
        });

        ws.on('error', (err) => {
          console.error(`[LuaBridge ${this.roomId}] WebSocket 错误:`, err);
          this.callbacks.onError(err.message);
        });

        // 发送队列中的待发送命令
        this.flushCommandQueue();
      });

      this.wss.on('error', (err) => {
        console.error(`[LuaBridge ${this.roomId}] 服务器错误:`, err);
        // 如果端口被占用，尝试文件 I/O
        if (!this.filePollingActive) {
          this.startFilePolling();
          this.isReady = true;
          resolve();
        }
      });

      console.log(`[LuaBridge ${this.roomId}] 监听端口 ${this.port} (WebSocket) + 文件 I/O ${this.pipeInPath}`);
    });
  }

  stop(): Promise<void> {
    return new Promise((resolve) => {
      this.stopFilePolling();
      if (this.ws) {
        this.ws.close();
        this.ws = null;
      }
      if (this.wss) {
        this.wss.close(() => {
          console.log(`[LuaBridge ${this.roomId}] 已关闭`);
          resolve();
        });
        this.wss = null;
      } else {
        resolve();
      }
    });
  }

  send(command: LuaCommand): boolean {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(command));
      return true;
    } else if (this.filePollingActive) {
      // 通过文件 I/O 发送命令
      return this.sendViaFile(command);
    } else {
      this.commandQueue.push(command);
      return false;
    }
  }

  private sendViaFile(command: LuaCommand): boolean {
    try {
      fs.appendFileSync(this.pipeOutPath, JSON.stringify(command) + '\n');
      return true;
    } catch (err) {
      console.error(`[LuaBridge ${this.roomId}] 文件写入失败:`, err);
      return false;
    }
  }

  getReady(): boolean {
    return this.isReady;
  }

  private ensurePipeFiles(): void {
    try {
      // 确保目录存在
      const dir = '/tmp';
      if (!fs.existsSync(this.pipeInPath)) {
        fs.writeFileSync(this.pipeInPath, '');
      }
      if (!fs.existsSync(this.pipeOutPath)) {
        fs.writeFileSync(this.pipeOutPath, '');
      }
    } catch (err) {
      console.warn(`[LuaBridge ${this.roomId}] 创建管道文件失败:`, err);
    }
  }

  private startFilePolling(): void {
    if (this.filePollingActive) return;
    this.filePollingActive = true;
    console.log(`[LuaBridge ${this.roomId}] 启动文件轮询: ${this.pipeInPath}`);

    // 文件模式下也能发送启动前缓存的指令
    this.flushCommandQueue();

    this.checkInterval = setInterval(() => {
      try {
        if (!fs.existsSync(this.pipeInPath)) return;
        const content = fs.readFileSync(this.pipeInPath, 'utf-8');
        if (content && content.length > 0) {
          // 清空文件（原子性较差，但单进程足够）
          fs.writeFileSync(this.pipeInPath, '');
          // 按行解析
          for (const line of content.split('\n')) {
            const trimmed = line.trim();
            if (trimmed.length > 0) {
              this.handleMessage(trimmed);
            }
          }
        }
      } catch (err) {
        // 文件读取失败，忽略
      }
    }, 100); // 100ms 轮询
  }

  private stopFilePolling(): void {
    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = null;
    }
    this.filePollingActive = false;
  }

  private handleMessage(raw: string): void {
    try {
      // 处理可能的 stdout 混合格式 (LUA_EVENT:{...})
      const jsonStart = raw.indexOf('{');
      const jsonStr = jsonStart >= 0 ? raw.substring(jsonStart) : raw;
      const event = JSON.parse(jsonStr) as LuaEvent;

      switch (event.event) {
        case 'ready':
          this.callbacks.onReady((event as any).rom || 'unknown');
          break;
        case 'update': {
          const ev = event as any;
          this.callbacks.onStateUpdate(
            ev.p1Hp || 0,
            ev.p2Hp || 0,
            ev.p1X || 0,
            ev.p2X || 0
          );
          break;
        }
        case 'round_end': {
          const ev = event as any;
          this.callbacks.onRoundEnd(
            ev.winner as 1 | 2,
            ev.round || 0,
            ev.p1Health || 0,
            ev.p2Health || 0
          );
          break;
        }
        case 'game_end': {
          const ev = event as any;
          this.callbacks.onGameEnd(
            ev.winner as 1 | 2,
            ev.p1Wins || 0,
            ev.p2Wins || 0
          );
          break;
        }
        case 'phase_change': {
          const ev = event as any;
          this.callbacks.onPhaseChange(ev.phase as GamePhase);
          break;
        }
        default:
          console.log(`[LuaBridge ${this.roomId}] 未处理事件: ${(event as any).event}`);
      }
    } catch (err) {
      console.error(`[LuaBridge ${this.roomId}] 消息解析失败:`, raw.substring(0, 200));
    }
  }

  private flushCommandQueue(): void {
    while (this.commandQueue.length > 0) {
      const cmd = this.commandQueue.shift()!;
      if (this.ws && this.ws.readyState === WebSocket.OPEN) {
        this.ws.send(JSON.stringify(cmd));
      } else if (this.filePollingActive) {
        this.sendViaFile(cmd);
      } else {
        // 既无 WebSocket 也无文件轮询，塞回队列并停止
        this.commandQueue.unshift(cmd);
        break;
      }
    }
  }
}
