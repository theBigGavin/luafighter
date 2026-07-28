import { exec, spawn, ChildProcess } from 'child_process';
import { promisify } from 'util';
import { v4 as uuidv4 } from 'uuid';
import {
  GameState,
  GamePhase,
  RoomConfig,
  RoomStatus,
  MarketStrength,
  LuaEvent,
  LuaCommand,
  StrategyCommand,
  MoveTendency,
  LUA_WS_PORT_BASE,
} from '@luafighter/shared-types';
import path from 'path';

const execAsync = promisify(exec);

/**
 * MAME 实例配置
 */
interface MameConfig {
  rom: string;
  display: string;
  wsPort: number;
  roomId: string;
  luaScriptPath: string;
  pluginPath: string;
  romsDir: string;
  windowed: boolean;
  soundEnabled: boolean;
  bios?: string;
}

/**
 * MAME 进程管理器
 * 负责启动、监控、重启 MAME 实例
 */
export class MameProcessManager {
  private process: ChildProcess | null = null;
  private config: MameConfig;
  private onExit: (code: number | null, signal: string | null) => void;
  private onOutput: (data: string) => void;
  private onError: (data: string) => void;
  private healthCheckTimer: NodeJS.Timeout | null = null;
  private lastHeartbeat: number = 0;
  private isHealthy: boolean = false;

  constructor(
    config: MameConfig,
    callbacks: {
      onExit: (code: number | null, signal: string | null) => void;
      onOutput: (data: string) => void;
      onError: (data: string) => void;
    }
  ) {
    this.config = config;
    this.onExit = callbacks.onExit;
    this.onOutput = callbacks.onOutput;
    this.onError = callbacks.onError;
  }

  async start(): Promise<void> {
    if (this.process) {
      throw new Error('MAME 进程已在运行');
    }

    const args = this.buildArgs();
    const mamePath = process.env.MAME_PATH || 'mame';
    console.log(`[MameProcess] 启动: ${mamePath} ${args.join(' ')}`);

    this.process = spawn(mamePath, args, {
      env: {
        ...process.env,
        LUAFIGHTER_ROM: this.config.rom,
        LUAFIGHTER_ROOM: this.config.roomId,
        LUAFIGHTER_HOST: 'localhost',
        LUAFIGHTER_PORT: this.config.wsPort.toString(),
        LUAFIGHTER_PATH: path.resolve(this.config.pluginPath, '..'),
        // DISPLAY 仅 Linux/Xvfb 需要；macOS 上设置 DISPLAY 会让 SDL 误用 X11
        ...(process.platform === 'linux' ? {
          DISPLAY: this.config.display,
          PULSE_SINK: process.env.PULSE_SINK || 'luafighter',
          PULSE_SERVER: process.env.PULSE_SERVER || 'unix:/tmp/pulse/native',
        } : {}),
      },
      cwd: this.config.romsDir,
      detached: false,
    });

    this.process.stdout?.on('data', (data: Buffer) => {
      const str = data.toString();
      this.onOutput(str);
      this.checkHeartbeat(str);
    });

    this.process.stderr?.on('data', (data: Buffer) => {
      this.onError(data.toString());
    });

    this.process.on('exit', (code, signal) => {
      console.log(`[MameProcess] 进程退出 code=${code} signal=${signal}`);
      this.isHealthy = false;
      this.onExit(code, signal);
    });

    this.process.on('error', (err) => {
      console.error(`[MameProcess] 进程错误:`, err);
      this.isHealthy = false;
    });

    // 启动健康检查
    this.startHealthCheck();

    // 等待启动完成
      await this.waitForReady(45000);
  }

  stop(signal: string = 'SIGTERM'): Promise<void> {
    return new Promise((resolve) => {
      if (!this.process) {
        resolve();
        return;
      }

      this.stopHealthCheck();
      
      const timeout = setTimeout(() => {
        console.log('[MameProcess] 强制终止进程');
        this.process?.kill('SIGKILL');
        resolve();
      }, 5000);

      this.process.on('exit', () => {
        clearTimeout(timeout);
        this.process = null;
        resolve();
      });

      this.process.kill(signal as NodeJS.Signals);
    });
  }

  isRunning(): boolean {
    return this.process !== null && !this.process.killed;
  }

  getHealth(): boolean {
    return this.isHealthy && this.isRunning();
  }

  private buildArgs(): string[] {
    const pluginPath = process.env.PLUGIN_PATH
      ? path.resolve(process.env.PLUGIN_PATH)
      : path.resolve(this.config.pluginPath);
    const args: string[] = [
      this.config.rom,
      '-rompath', path.resolve(this.config.romsDir),
      '-plugins',
      '-pluginspath', pluginPath,
      '-plugin', 'luafighter',
      '-resolution', '768x448',
      '-skip_gameinfo',
      // Linux/Docker 用 /app/cfg（容器内路径）；本地（macOS）用项目 cfg 目录
      '-cfg_directory', process.platform === 'linux' ? '/app/cfg' : path.resolve('./cfg'),
    ];

    // PulseAudio 仅 Linux 可用；macOS 本地开发静音
    if (process.platform === 'linux' && this.config.soundEnabled) {
      args.push('-sound', 'pulse');
    } else {
      args.push('-sound', 'none');
    }

    if (this.config.bios) {
      args.push('-bios', this.config.bios);
    }

    return args;
  }

  private checkHeartbeat(output: string): void {
    if (output.includes('[LuaFighter]') || output.includes('LUA_EVENT:')) {
      this.lastHeartbeat = Date.now();
      this.isHealthy = true;
    }
  }

  private startHealthCheck(): void {
    this.lastHeartbeat = Date.now();
    this.healthCheckTimer = setInterval(() => {
      const elapsed = Date.now() - this.lastHeartbeat;
      if (elapsed > 10000) { // 10秒无心跳视为不健康
        this.isHealthy = false;
        console.warn(`[MameProcess] 健康检查失败: ${elapsed}ms 无心跳`);
      }
    }, 5000);
  }

  private stopHealthCheck(): void {
    if (this.healthCheckTimer) {
      clearInterval(this.healthCheckTimer);
      this.healthCheckTimer = null;
    }
  }

  private waitForReady(timeout: number): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('MAME 启动超时'));
      }, timeout);

      const checkInterval = setInterval(() => {
        if (this.isHealthy) {
          clearTimeout(timer);
          clearInterval(checkInterval);
          resolve();
        }
      }, 500);
    });
  }

  softReset(): void {
    if (this.process?.stdin?.writable) {
      this.process.stdin.write('F3\n');
    }
  }
}

/**
 * MAME 实例池
 * 管理多个 MAME 进程，支持复用和分配
 */
export class MamePool {
  private instances: Map<string, MameProcessManager> = new Map();
  private poolSize: number;
  private romsDir: string;
  private luaScriptPath: string;
  private pluginPath: string;
  private displayBase: number;

  constructor(options: {
    poolSize: number;
    romsDir: string;
    luaScriptPath: string;
    pluginPath: string;
    displayBase?: number;
  }) {
    this.poolSize = options.poolSize;
    this.romsDir = options.romsDir;
    this.luaScriptPath = options.luaScriptPath;
    this.pluginPath = options.pluginPath;
    this.displayBase = options.displayBase || 99;
  }

  async createInstance(roomId: string, rom: string, bios?: string): Promise<{ manager: MameProcessManager; display: string; wsPort: number }> {
    const displayNum = this.displayBase + this.instances.size;
    const display = `:${displayNum}`;
    const wsPort = LUA_WS_PORT_BASE + displayNum;

    const config: MameConfig = {
      rom,
      display,
      wsPort,
      roomId,
      luaScriptPath: this.luaScriptPath,
      pluginPath: this.pluginPath,
      romsDir: this.romsDir,
      windowed: true,
      soundEnabled: true,
      bios,
    };

    const manager = new MameProcessManager(config, {
      onExit: (code, signal) => {
        console.log(`[MamePool] ${roomId} 进程退出`);
        this.instances.delete(roomId);
      },
      onOutput: (data) => {
        // 日志可过滤
        if (data.includes('[LuaFighter]') || data.includes('错误') || data.includes('Error')) {
          console.log(`[MAME ${roomId}] ${data.trim()}`);
        }
      },
      onError: (data) => {
        console.error(`[MAME ${roomId} stderr] ${data.trim()}`);
      },
    });

    await manager.start();
    this.instances.set(roomId, manager);
    return { manager, display, wsPort };
  }

  async destroyInstance(roomId: string): Promise<void> {
    const instance = this.instances.get(roomId);
    if (instance) {
      await instance.stop();
      this.instances.delete(roomId);
    }
  }

  getInstance(roomId: string): MameProcessManager | undefined {
    return this.instances.get(roomId);
  }

  getAllInstances(): Map<string, MameProcessManager> {
    return this.instances;
  }

  getHealthyCount(): number {
    let count = 0;
    for (const [, instance] of this.instances) {
      if (instance.getHealth()) count++;
    }
    return count;
  }
}
