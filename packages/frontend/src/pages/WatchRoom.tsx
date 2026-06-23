import { useEffect, useState, useCallback, useRef } from 'react';
import { useParams } from 'react-router-dom';
import { io, Socket } from 'socket.io-client';
import StrengthChart from '../components/StrengthChart';
import ScoreBoard from '../components/ScoreBoard';
import VideoPlayer from '../components/VideoPlayer';
import MarketPanel from '../components/MarketPanel';
import ConnectionStatus from '../components/ConnectionStatus';

interface GameState {
  roomId: string;
  rom: string;
  phase: string;
  round: {
    round: number;
    p1: { health: number; maxHealth: number; x: number };
    p2: { health: number; maxHealth: number; x: number };
    timeRemaining: number;
  } | null;
  score: { p1Wins: number; p2Wins: number; totalRounds: number; bestOf: number };
  marketData: {
    symbol: string;
    strengthIndex: number;
    bidAmountTotal: number;
    askAmountTotal: number;
    bidVolumeTotal?: number;
    askVolumeTotal?: number;
    diffRatio?: number;
    lastPrice?: number;
    priceChange?: number;
    timestamp?: number;
  } | null;
}

/**
 * 对战观看页面
 * 集成视频播放、比分板、多空数据、投注面板
 */

export default function WatchRoom() {
  const { roomId } = useParams<{ roomId: string }>();
  const socketRef = useRef<Socket | null>(null);
  const [connected, setConnected] = useState(false);
  const [gameState, setGameState] = useState<GameState | null>(null);
  const [strengthHistory, setStrengthHistory] = useState<{ time: number; value: number }[]>([]);
  const [webrtcUrl, setWebrtcUrl] = useState<string>('');
  const [hlsUrl, setHlsUrl] = useState<string>('');

  const appendStrength = useCallback((strengthIndex: number) => {
    setStrengthHistory((prev) => {
      const now = Date.now();
      const next = [...prev, { time: now, value: strengthIndex }].filter(
        (d) => now - d.time <= 60000
      );
      return next;
    });
  }, []);

  // 连接 Socket.IO
  useEffect(() => {
    if (!roomId) return;

    const s = io('/', {
      path: '/socket.io',
      transports: ['websocket'],
    });
    socketRef.current = s;

    s.on('connect', () => {
      console.log('[Socket] 已连接');
      setConnected(true);
      s.emit('join', roomId);
    });

    s.on('disconnect', () => {
      console.log('[Socket] 已断开');
      setConnected(false);
    });

    s.on('gameState', (state: GameState) => {
      setGameState(state);
      if (state.marketData) {
        appendStrength(state.marketData.strengthIndex);
      }
    });

    s.on('joined', (data: { roomId: string; state: GameState }) => {
      setGameState(data.state);
      if (data.state.marketData) {
        appendStrength(data.state.marketData.strengthIndex);
      }
    });

    s.on('error', (err: { message?: string } | string) => {
      console.error('[Socket] 错误:', err);
    });

    return () => {
      s.emit('leave', roomId);
      s.disconnect();
      socketRef.current = null;
    };
  }, [roomId, appendStrength]);

  // 获取播放地址（HLS 直接访问 mediamtx 8888 端口，绕过 nginx 代理）
  useEffect(() => {
    if (!roomId) return;
    // HLS 直接访问 mediamtx 的 8888 端口，避免 nginx 代理导致端口丢失
    const hlsDirectUrl = `http://${window.location.hostname}:8888/hls/live/room_${roomId}/index.m3u8`;
    setHlsUrl(hlsDirectUrl);
    
    fetch(`/api/streams/${roomId}`)
      .then((res) => res.json())
      .then((data) => {
        if (data.webrtcUrl) setWebrtcUrl(data.webrtcUrl);
      })
      .catch(console.error);
  }, [roomId]);

  if (!roomId) return <div>房间 ID 无效</div>;

  return (
    <div className="watch-room">
      <div className="video-section">
        <div className="video-container-wrapper">
          <VideoPlayer webrtcUrl={webrtcUrl} hlsUrl={hlsUrl} roomId={roomId} />
          <ConnectionStatus connected={connected} phase={gameState?.phase || 'unknown'} />
        </div>
      </div>

      <div className="sidebar">
        <ScoreBoard
              compact
              p1Hp={gameState?.round?.p1.health || 0}
              p2Hp={gameState?.round?.p2.health || 0}
              p1MaxHp={gameState?.round?.p1.maxHealth || 144}
              p2MaxHp={gameState?.round?.p2.maxHealth || 144}
              p1Wins={gameState?.score.p1Wins || 0}
              p2Wins={gameState?.score.p2Wins || 0}
              round={gameState?.round?.round || 1}
              bestOf={gameState?.score.bestOf || 3}
              phase={gameState?.phase || 'unknown'}
            />
        <MarketPanel
          strength={gameState?.marketData?.strengthIndex || 0}
          bidAmount={gameState?.marketData?.bidAmountTotal || 0}
          askAmount={gameState?.marketData?.askAmountTotal || 0}
          bidVolume={gameState?.marketData?.bidVolumeTotal || 0}
          askVolume={gameState?.marketData?.askVolumeTotal || 0}
          lastPrice={gameState?.marketData?.lastPrice}
          priceChange={gameState?.marketData?.priceChange}
          symbol={gameState?.marketData?.symbol || 'IF2306'}
        />

        <div className="panel trend-panel">
          <h3 className="panel-title">多空趋势</h3>
          <StrengthChart data={strengthHistory} />
        </div>
      </div>
    </div>
  );
}
