import { useEffect, useState, useCallback, useRef } from 'react';
import { useParams } from 'react-router-dom';
import { io, Socket } from 'socket.io-client';
import StrengthChart from '../components/StrengthChart';
import ScoreBoard from '../components/ScoreBoard';
import VideoPlayer from '../components/VideoPlayer';
import MarketPanel from '../components/MarketPanel';
import BettingPanel from '../components/BettingPanel';
import ConnectionStatus from '../components/ConnectionStatus';
import { useBetting } from '../hooks/useBetting';

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

  const { balance, records, placeBet, settleRound, settleGame } = useBetting(10000);

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

    s.on('roundEnd', (data: { winner: 1 | 2; round: number }) => {
      settleRound({ winner: data.winner, round: data.round });
    });

    s.on('gameEnd', (data: { winner: 1 | 2; p1Wins: number; p2Wins: number }) => {
      settleGame({ winner: data.winner, p1Wins: data.p1Wins, p2Wins: data.p2Wins });
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
  }, [roomId, appendStrength, settleRound, settleGame]);

  // 获取播放地址
  useEffect(() => {
    if (!roomId) return;
    fetch(`/api/streams/${roomId}`)
      .then((res) => res.json())
      .then((data) => {
        if (data.webrtcUrl) setWebrtcUrl(data.webrtcUrl);
        if (data.hlsUrl) setHlsUrl(data.hlsUrl);
      })
      .catch(console.error);
  }, [roomId]);

  const handlePlaceBet = useCallback(
    (side: 'p1' | 'p2', amount: number) => {
      const round = gameState?.round?.round || 1;
      const strength = gameState?.marketData?.strengthIndex || 0;
      return placeBet(side, amount, strength, round);
    },
    [gameState, placeBet]
  );

  if (!roomId) return <div>房间 ID 无效</div>;

  return (
    <div className="watch-room">
      <div className="video-section">
        <div className="video-container-wrapper">
          <VideoPlayer webrtcUrl={webrtcUrl} hlsUrl={hlsUrl} roomId={roomId} />
          <div className="scoreboard-overlay">
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
          </div>
          <ConnectionStatus connected={connected} phase={gameState?.phase || 'unknown'} />
        </div>

        <div className="panel trend-panel">
          <h3 className="panel-title">多空趋势</h3>
          <StrengthChart data={strengthHistory} />
        </div>
      </div>

      <div className="sidebar">
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

        <BettingPanel
          balance={balance}
          records={records}
          strengthIndex={gameState?.marketData?.strengthIndex || 0}
          currentRound={gameState?.round?.round || 1}
          phase={gameState?.phase || 'unknown'}
          onPlaceBet={handlePlaceBet}
        />
      </div>
    </div>
  );
}
