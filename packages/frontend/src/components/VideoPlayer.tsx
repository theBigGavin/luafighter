import { useRef, useEffect, useState, useCallback } from 'react';
import Hls from 'hls.js';

interface VideoPlayerProps {
  webrtcUrl?: string;
  hlsUrl?: string;
  roomId: string;
}

/**
 * 视频播放器
 * 当前使用 HLS（通过 hls.js）播放，兼容 Docker / NAT 环境。
 * WebRTC(WHEP) 在低延迟场景更优，但在当前 Docker Desktop 网络下 ICE 穿透困难，
 * 因此保留 webrtcUrl 接口但默认走 HLS。
 *
 * 浏览器端常见问题与对策：
 * - m3u8 / part 缓存导致旧片段反复播放 → xhrSetup 加 Cache-Control: no-cache
 * - 网络抖动后 hls.js 不再自动恢复 → 对 fatal error 做分级重试
 * - 解码错误导致黑屏 → recoverMediaError + swapAudioCodec
 * - 无限快速重试 → 指数退避，最大重试次数
 */

export default function VideoPlayer({ hlsUrl, roomId }: VideoPlayerProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const hlsRef = useRef<Hls | null>(null);
  const retryCountRef = useRef(0);
  const retryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [status, setStatus] = useState<'waiting' | 'playing' | 'error'>('waiting');
  const [retryTick, setRetryTick] = useState(0);

  const clearRetryTimer = useCallback(() => {
    if (retryTimerRef.current) {
      clearTimeout(retryTimerRef.current);
      retryTimerRef.current = null;
    }
  }, []);

  const createHlsInstance = useCallback((video: HTMLVideoElement, source: string) => {
    const hls = new Hls({
      enableWorker: false,
      lowLatencyMode: true,
      maxBufferLength: 5,
      maxMaxBufferLength: 10,
      liveSyncDurationCount: 3,
      liveMaxLatencyDurationCount: 6,
    });

    hlsRef.current = hls;

    hls.on(Hls.Events.MANIFEST_PARSED, () => {
      retryCountRef.current = 0;
      setStatus('playing');
      video.play().catch(() => {});
    });

    hls.on(Hls.Events.ERROR, (_event, data) => {
      console.error('[VideoPlayer] HLS error:', data);

      if (!data.fatal) {
        // 非致命错误：缓冲 stall、片段加载超时等，通常 hls.js 会自行恢复
        if (data.details === Hls.ErrorDetails.BUFFER_STALLED_ERROR) {
          video.play().catch(() => {});
        }
        return;
      }

      if (retryCountRef.current >= 5) {
        setStatus('error');
        return;
      }

      retryCountRef.current += 1;
      const delay = Math.min(1000 * 2 ** (retryCountRef.current - 1), 8000);

      clearRetryTimer();
      retryTimerRef.current = setTimeout(() => {
        const currentHls = hlsRef.current;
        if (!currentHls) return;

        if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
          // 网络类错误先尝试恢复加载；仍失败则重建实例
          if (data.details === Hls.ErrorDetails.MANIFEST_LOAD_ERROR) {
            setRetryTick((t) => t + 1);
          } else {
            currentHls.startLoad();
          }
        } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
          // 解码/渲染类错误：先恢复媒体，重试多次后仍失败则换 codec
          if (retryCountRef.current >= 3) {
            currentHls.swapAudioCodec();
          }
          currentHls.recoverMediaError();
        } else {
          // 其它致命错误：重建播放器实例
          setRetryTick((t) => t + 1);
        }
      }, delay);
    });

    hls.loadSource(source);
    hls.attachMedia(video);
  }, [clearRetryTimer]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video || !hlsUrl) return;

    setStatus('waiting');
    retryCountRef.current = 0;
    clearRetryTimer();

    // 清理上一次的状态
    video.pause();
    video.srcObject = null;
    video.src = '';
    video.load();

    let hls: Hls | null = null;

    if (Hls.isSupported()) {
      // 重试时给 m3u8 加时间戳，避免浏览器/代理缓存旧的播放列表
      const source = retryTick > 0 ? `${hlsUrl}${hlsUrl.includes('?') ? '&' : '?'}_t=${Date.now()}` : hlsUrl;
      createHlsInstance(video, source);
      hls = hlsRef.current;
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      // Safari / iOS 原生支持 HLS
      video.src = hlsUrl;
      video.play().catch(() => {});
      setStatus('playing');
    } else {
      setStatus('error');
    }

    return () => {
      clearRetryTimer();
      hls?.destroy();
      hlsRef.current = null;
    };
  }, [hlsUrl, retryTick, createHlsInstance, clearRetryTimer]);

  const handleManualRetry = () => {
    retryCountRef.current = 0;
    setRetryTick((t) => t + 1);
  };

  const showPlaceholder = !hlsUrl;

  return (
    <div className="video-container">
      {showPlaceholder ? (
        <div className="video-placeholder">
          <div className="icon">📺</div>
          <div>等待视频流...</div>
          <div style={{ fontSize: '12px', opacity: 0.6 }}>房间: {roomId}</div>
        </div>
      ) : (
        <>
          <video
            ref={videoRef}
            autoPlay
            playsInline
            controls={false}
            muted={false}
            style={{ width: '100%', height: '100%', objectFit: 'contain' }}
          />
          {status === 'waiting' && (
            <div className="video-overlay">
              <div>正在连接视频流...</div>
            </div>
          )}
          {status === 'error' && (
            <div className="video-overlay error">
              <div>视频流播放失败</div>
              <button type="button" className="retry-button" onClick={handleManualRetry}>
                重试
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}
