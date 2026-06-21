import { useRef, useEffect } from 'react';

interface VideoPlayerProps {
  webrtcUrl: string;
  roomId: string;
}

/**
 * WebRTC 视频播放器
 * 使用 WHEP 协议从 MediaMTX 接收视频流
 */

export default function VideoPlayer({ webrtcUrl, roomId }: VideoPlayerProps) {
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    if (!webrtcUrl || !videoRef.current) return;

    const video = videoRef.current;

    // 使用 WHEP 协议（WebRTC-HTTP Egress Protocol）
    // 这是 MediaMTX 支持的 WebRTC 播放方式
    const whepUrl = `${webrtcUrl}/whep`;

    // 简单的 WHIP/WHEP 客户端实现
    let pc: RTCPeerConnection | null = null;

    async function startPlayback() {
      try {
        pc = new RTCPeerConnection({
          iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
        });

        pc.addTransceiver('video', { direction: 'recvonly' });
        pc.addTransceiver('audio', { direction: 'recvonly' });

        pc.ontrack = (event) => {
          if (event.track.kind === 'video' && video.srcObject !== event.streams[0]) {
            video.srcObject = event.streams[0];
            video.play().catch(() => {});
          }
        };

        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);

        // 等待 ICE 收集完成
        await new Promise<void>((resolve) => {
          const checkState = () => {
            if (pc?.iceGatheringState === 'complete') {
              resolve();
            } else {
              setTimeout(checkState, 100);
            }
          };
          checkState();
        });

        // 发送 offer 到 WHEP 端点
        const response = await fetch(whepUrl, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/sdp',
          },
          body: pc.localDescription?.sdp,
        });

        if (!response.ok) {
          throw new Error(`WHEP 请求失败: ${response.status}`);
        }

        const answerSdp = await response.text();
        await pc.setRemoteDescription({ type: 'answer', sdp: answerSdp });

      } catch (err) {
        console.error('[VideoPlayer] WebRTC 播放失败:', err);
      }
    }

    startPlayback();

    return () => {
      pc?.close();
      pc = null;
      video.srcObject = null;
    };
  }, [webrtcUrl]);

  return (
    <div className="video-container">
      {webrtcUrl ? (
        <video
          ref={videoRef}
          autoPlay
          playsInline
          muted
          controls={false}
          style={{ width: '100%', height: '100%', objectFit: 'contain' }}
        />
      ) : (
        <div className="video-placeholder">
          <div className="icon">📺</div>
          <div>等待视频流...</div>
          <div style={{ fontSize: '12px', opacity: 0.6 }}>房间: {roomId}</div>
        </div>
      )}
    </div>
  );
}
