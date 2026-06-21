interface ConnectionStatusProps {
  connected: boolean;
  phase: string;
}

function translatePhase(phase: string): string {
  const map: Record<string, string> = {
    attract: '标题画面',
    select: '选人',
    loading: '加载中',
    round_start: '对战',
    fighting: '对战',
    ko: 'KO',
    win: '胜利画面',
    round_end: 'Round 结束',
    game_end: '对局结束',
    unknown: '等待中',
  };
  return map[phase] || phase;
}

/**
 * 连接状态浮层
 * 显示在视频画面左下角，类似直播状态 badge
 */
export default function ConnectionStatus({ connected, phase }: ConnectionStatusProps) {
  return (
    <div className="connection-status">
      <span className={`connection-dot ${connected ? 'connected' : 'disconnected'}`} />
      <span>{connected ? '已连接' : '未连接'}</span>
      <span className="connection-divider">|</span>
      <span>{translatePhase(phase)}</span>
    </div>
  );
}
