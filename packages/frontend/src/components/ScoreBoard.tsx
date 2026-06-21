
interface ScoreBoardProps {
  p1Hp: number;
  p2Hp: number;
  p1MaxHp: number;
  p2MaxHp: number;
  p1Wins: number;
  p2Wins: number;
  round: number;
  bestOf: number;
  phase: string;
  connected: boolean;
}

/**
 * 比分板组件
 * 显示双方血量、比分、当前 Round
 */

export default function ScoreBoard({
  p1Hp,
  p2Hp,
  p1MaxHp,
  p2MaxHp,
  p1Wins,
  p2Wins,
  round,
  bestOf,
  phase,
  connected,
}: ScoreBoardProps) {
  const p1Percent = Math.max(0, Math.min(100, (p1Hp / p1MaxHp) * 100));
  const p2Percent = Math.max(0, Math.min(100, (p2Hp / p2MaxHp) * 100));

  const phaseText = {
    attract: '标题画面',
    select: '选人',
    loading: '加载中',
    round_start: '对战',
    fighting: '对战',
    round_end: 'Round 结束',
    game_end: '对局结束',
    unknown: '等待中',
  }[phase] || phase;

  return (
    <div className="scoreboard">
      <div className="scoreboard-header">
        <div className="scoreboard-title">
          {connected ? '🟢 已连接' : '🔴 未连接'} | {phaseText}
        </div>
        <div className="round-indicator">Round {round} / {bestOf}</div>
      </div>

      <div className="fighters-row">
        <div className="fighter-info">
          <div className="fighter-name p1">1P 多方</div>
          <div className="health-bar">
            <div
              className="health-fill p1"
              style={{ width: `${p1Percent}%` }}
            />
          </div>
          <div className="health-text">{Math.floor(p1Hp)} / {p1MaxHp} | 胜 {p1Wins}</div>
        </div>

        <div className="vs-divider">VS</div>

        <div className="fighter-info">
          <div className="fighter-name p2">2P 空方</div>
          <div className="health-bar">
            <div
              className="health-fill p2"
              style={{ width: `${p2Percent}%` }}
            />
          </div>
          <div className="health-text">{Math.floor(p2Hp)} / {p2MaxHp} | 胜 {p2Wins}</div>
        </div>
      </div>
    </div>
  );
}
