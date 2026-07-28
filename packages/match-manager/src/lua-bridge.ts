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
  // seq/ack 可靠传输：每条命令带递增 seq，Lua 回 ack；500ms 未确认则重发，最多 3 次
  private nextSeq: number = 1;
  private pendingAck = new Map<number, { command: LuaCommand; sentAt: number; retries: number }>();
  private ackTimer: NodeJS.Timeout | null = null;
  // 文件轮询读取偏移（append-only 增量读取，避免读后截断的丢消息竞态）
  private pipeInOffset: number = 0;

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
      if (this.ackTimer) {
        clearInterval(this.ackTimer);
        this.ackTimer = null;
      }
      this.pendingAck.clear();
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
    const cmd = { ...command, seq: this.nextSeq++ };
    if (!this.deliver(cmd)) {
      this.commandQueue.push(cmd);
      return false;
    }
    this.pendingAck.set(cmd.seq, { command: cmd, sentAt: Date.now(), retries: 0 });
    this.ensureAckTimer();
    return true;
  }

  private deliver(command: LuaCommand & { seq?: number }): boolean {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(command));
      return true;
    }
    if (this.filePollingActive) {
      // 通过文件 I/O 发送命令
      return this.sendViaFile(command);
    }
    return false;
  }

  private ensureAckTimer(): void {
    if (this.ackTimer) return;
    this.ackTimer = setInterval(() => {
      const now = Date.now();
      for (const [seq, pending] of this.pendingAck) {
        if (now - pending.sentAt < 500) continue;
        if (pending.retries >= 3) {
          this.pendingAck.delete(seq);
          console.error(`[LuaBridge ${this.roomId}] 命令 seq=${seq} 重发 3 次仍未收到 ack，已丢弃`);
          this.callbacks.onError(`command seq=${seq} lost (no ack after retries)`);
          continue;
        }
        pending.retries++;
        pending.sentAt = now;
        this.deliver(pending.command); // 通道暂不可用时下轮再试
      }
      if (this.pendingAck.size === 0 && this.ackTimer) {
        clearInterval(this.ackTimer);
        this.ackTimer = null;
      }
    }, 500);
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
      let fd: number | null = null;
      try {
        if (!fs.existsSync(this.pipeInPath)) return;
        const stat = fs.statSync(this.pipeInPath);
        if (stat.size < this.pipeInOffset) {
          // 文件被外部截断/轮转，从头读
          this.pipeInOffset = 0;
        }
        if (stat.size <= this.pipeInOffset) return;

        // append-only 增量读取：从上次偏移继续读，不截断文件，
        // 避免"读后清空"与 Lua 端 append 之间的丢消息竞态
        fd = fs.openSync(this.pipeInPath, 'r');
        const length = stat.size - this.pipeInOffset;
        const buffer = Buffer.alloc(length);
        const bytesRead = fs.readSync(fd, buffer, 0, length, this.pipeInOffset);
        if (bytesRead <= 0) return;

        const chunk = buffer.subarray(0, bytesRead);
        // 只处理完整行，未写完的半行留到下一轮
        const lastNewline = chunk.lastIndexOf(0x0a);
        if (lastNewline < 0) return;
        const complete = chunk.subarray(0, lastNewline).toString('utf-8');
        this.pipeInOffset += lastNewline + 1;

        for (const line of complete.split('\n')) {
          const trimmed = line.trim();
          if (trimmed.length > 0) {
            this.handleMessage(trimmed);
          }
        }
      } catch (err) {
        // 文件读取失败，忽略
      } finally {
        if (fd !== null) {
          try { fs.closeSync(fd); } catch { /* ignore */ }
        }
      }
    }, 100); // 100ms 轮询
  }

  private stopFilePolling(): void {
    if (this.checkInterval) {
      clearInterval(this.checkInterval);
      this.checkInterval = null;
    }
    this.filePollingActive = false;
    this.pipeInOffset = 0;
  }

  private handleMessage(raw: string): void {
    try {
      // 处理可能的 stdout 混合格式 (LUA_EVENT:{...})
      const jsonStart = raw.indexOf('{');
      const jsonStr = jsonStart >= 0 ? raw.substring(jsonStart) : raw;
      const event = JSON.parse(jsonStr) as LuaEvent;

      // 命令确认：清除对应 seq 的重发跟踪
      if ((event as any).event === 'ack') {
        const ackSeq = (event as any).seq;
        if (typeof ackSeq === 'number') {
          this.pendingAck.delete(ackSeq);
        }
        return;
      }

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
    const queued = this.commandQueue.splice(0);
    for (const cmd of queued) {
      // 走 send() 统一入口：重新分配 seq 并纳入 ack 跟踪；
      // 通道仍不可用时 send() 会把命令塞回队列，此时停止避免空转
      if (!this.send(cmd)) break;
    }
  }
}
