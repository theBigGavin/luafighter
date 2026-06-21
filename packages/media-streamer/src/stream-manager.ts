import { spawn, ChildProcess } from 'child_process';
import path from 'path';

/**
 * FFmpeg 捕获与推流管理器
 * 管理 MAME 画面的捕获和 RTMP 推流
 */

export interface StreamConfig {
  roomId: string;
  display: string;
  windowId?: string;
  rtmpUrl: string;
  width: number;
  height: number;
  fps: number;
  bitrate: string;
}

export class FFmpegStreamer {
  private process: ChildProcess | null = null;
  private config: StreamConfig;
  private onError: (err: string) => void;
  private onExit: (code: number | null) => void;
  private isRunning: boolean = false;

  constructor(
    config: StreamConfig,
    callbacks: {
      onError: (err: string) => void;
      onExit: (code: number | null) => void;
    }
  ) {
    this.config = config;
    this.onError = callbacks.onError;
    this.onExit = callbacks.onExit;
  }

  async start(): Promise<void> {
    if (this.process) {
      throw new Error('FFmpeg 已在运行');
    }

    const args = this.buildArgs();
    console.log(`[FFmpeg] 启动推流: ${args.join(' ')}`);

    this.process = spawn('ffmpeg', args, {
      env: process.env,
      detached: false,
    });

    this.process.stdout?.on('data', (data: Buffer) => {
      const str = data.toString();
      if (str.includes('Error') || str.includes('error')) {
        console.error(`[FFmpeg ${this.config.roomId}] ${str.trim()}`);
      }
    });

    this.process.stderr?.on('data', (data: Buffer) => {
      const str = data.toString();
      // FFmpeg 进度信息在 stderr 输出
      if (str.includes('frame=') && str.includes('fps=')) {
        // 可选：解析实时帧率
      }
    });

    this.process.on('exit', (code) => {
      console.log(`[FFmpeg ${this.config.roomId}] 进程退出 code=${code}`);
      this.isRunning = false;
      this.onExit(code);
    });

    this.process.on('error', (err) => {
      console.error(`[FFmpeg ${this.config.roomId}] 进程错误:`, err);
      this.onError(err.message);
    });

    this.isRunning = true;

    // 等待启动
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }

  stop(): Promise<void> {
    return new Promise((resolve) => {
      if (!this.process) {
        resolve();
        return;
      }

      const timeout = setTimeout(() => {
        this.process?.kill('SIGKILL');
        resolve();
      }, 3000);

      this.process.on('exit', () => {
        clearTimeout(timeout);
        this.process = null;
        this.isRunning = false;
        resolve();
      });

      this.process.kill('SIGTERM');
    });
  }

  getRunning(): boolean {
    return this.isRunning;
  }

  private buildArgs(): string[] {
    const { display, width, height, fps, bitrate, rtmpUrl } = this.config;

    // macOS 使用 avfoundation 捕获屏幕
    // Linux 使用 x11grab 捕获 X11 显示
    const platform = process.platform;
    const inputArgs: string[] = [];

    if (platform === 'darwin') {
      // macOS: 使用 avfoundation 捕获主屏幕
      // 需要先获取窗口 ID，这里简化为捕获整个屏幕
      inputArgs.push('-f', 'avfoundation');
      inputArgs.push('-i', '1:0'); // 视频:音频
      inputArgs.push('-s', `${width}x${height}`);
    } else {
      // Linux: 使用 x11grab 捕获 Xvfb 显示
      inputArgs.push('-f', 'x11grab');
      inputArgs.push('-draw_mouse', '0');
      inputArgs.push('-r', fps.toString());
      inputArgs.push('-s', `${width}x${height}`);
      inputArgs.push('-i', `${display}.0+0,0`);

      // 捕获 PulseAudio null sink 的 monitor 作为音频源
      inputArgs.push('-f', 'pulse');
      inputArgs.push('-i', `${process.env.PULSE_SINK || 'luafighter'}.monitor`);
    }

    const outputArgs: string[] = [
      '-vcodec', 'libx264',
      '-preset', 'ultrafast',
      '-tune', 'zerolatency',
      '-b:v', bitrate,
      '-maxrate', bitrate,
      '-bufsize', '500k',
      '-g', fps.toString(), // 1秒关键帧间隔，匹配 HLS segment
      '-keyint_min', fps.toString(),
      '-sc_threshold', '0',
      '-pix_fmt', 'yuv420p',
      '-acodec', 'aac',
      '-b:a', '128k',
      '-ar', '48000',
      '-ac', '2',
      '-f', 'flv',
      rtmpUrl,
    ];

    return [...inputArgs, ...outputArgs];
  }
}

/**
 * 推流服务管理器
 * 管理所有房间的 FFmpeg 进程
 */

export class StreamManager {
  private streamers: Map<string, FFmpegStreamer> = new Map();
  private mediaMtxUrl: string;

  constructor(mediaMtxUrl?: string) {
    this.mediaMtxUrl = mediaMtxUrl || process.env.MEDIA_MTX_URL || 'rtmp://localhost:1935/live';
  }

  async startStream(roomId: string, display: string): Promise<string> {
    const streamKey = `room_${roomId}`;
    const rtmpUrl = `${this.mediaMtxUrl}/${streamKey}`;

    const config: StreamConfig = {
      roomId,
      display,
      rtmpUrl,
      width: 640,
      height: 480,
      fps: 30,
      bitrate: '1500k',
    };

    const streamer = new FFmpegStreamer(config, {
      onError: (err) => {
        console.error(`[StreamManager] ${roomId} 推流错误:`, err);
      },
      onExit: (code) => {
        console.log(`[StreamManager] ${roomId} 推流结束 code=${code}`);
        this.streamers.delete(roomId);
      },
    });

    await streamer.start();
    this.streamers.set(roomId, streamer);

    console.log(`[StreamManager] 房间 ${roomId} 推流已启动: ${rtmpUrl}`);
    return rtmpUrl;
  }

  async stopStream(roomId: string): Promise<void> {
    const streamer = this.streamers.get(roomId);
    if (streamer) {
      await streamer.stop();
      this.streamers.delete(roomId);
      console.log(`[StreamManager] 房间 ${roomId} 推流已停止`);
    }
  }

  getWebRTCUrl(roomId: string): string {
    // MediaMTX 的 WebRTC 播放地址（通过 Nginx /webrtc 代理访问）
    const streamKey = `room_${roomId}`;
    return `/webrtc/live/${streamKey}`;
  }

  getHlsUrl(roomId: string): string {
    // MediaMTX 的 HLS 播放地址（通过 Nginx /hls 代理访问）
    const streamKey = `room_${roomId}`;
    return `/hls/live/${streamKey}/index.m3u8`;
  }

  getStreamInfo(roomId: string): {
    streaming: boolean;
    rtmpUrl: string;
    webrtcUrl: string;
    hlsUrl: string;
  } {
    const streamer = this.streamers.get(roomId);
    const streaming = streamer?.getRunning() || false;
    return {
      streaming,
      rtmpUrl: `${this.mediaMtxUrl}/room_${roomId}`,
      webrtcUrl: this.getWebRTCUrl(roomId),
      hlsUrl: this.getHlsUrl(roomId),
    };
  }
}
