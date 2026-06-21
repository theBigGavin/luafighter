import { useRef, useEffect, useState } from 'react';
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
 */

export default function VideoPlayer({ hlsUrl, roomId }: VideoPlayerProps) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const hlsRef = useRef<Hls | null>(null);
  const [status, setStatus] = useState<'waiting' | 'playing' | 'error'>('waiting');

  useEffect(() => {
    const video = videoRef.current;
    if (!video || !hlsUrl) return;

    setStatus('waiting');

    // 清理上一次的状态
    video.srcObject = null;
    video.src = '';
    video.load();

    let hls: Hls | null = null;

    if (Hls.isSupported()) {
      // 优先使用 hls.js，避免 Chrome 报告 canPlayType('maybe') 却无法解码
      hls = new Hls({
        enableWorker: false,
        lowLatencyMode: true,
        maxBufferLength: 4,
        maxMaxBufferLength: 8,
      });
      hlsRef.current = hls;

      hls.loadSource(hlsUrl);
      hls.attachMedia(video);

      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        setStatus('playing');
        video.play().catch(() => {});
      });

      hls.on(Hls.Events.ERROR, (_event, data) => {
        console.error('[VideoPlayer] HLS error:', data);
        if (data.fatal) {
          setStatus('error');
        }
      });
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      // Safari / iOS 原生支持 HLS
      video.src = hlsUrl;
      video.play().catch(() => {});
      setStatus('playing');
    } else {
      setStatus('error');
    }

    return () => {
      hls?.destroy();
      hlsRef.current = null;
    };
  }, [hlsUrl]);

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
            muted
            controls={false}
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
            </div>
          )}
        </>
      )}
    </div>
  );
}
