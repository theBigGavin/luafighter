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
  compact?: boolean;
}

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
  compact = false,
}: ScoreBoardProps) {
  const p1Percent = Math.max(0, Math.min(100, (p1Hp / p1MaxHp) * 100));
  const p2Percent = Math.max(0, Math.min(100, (p2Hp / p2MaxHp) * 100));

  const phaseText: Record<string, string> = {
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

  if (compact) {
    return (
      <div className="scoreboard compact">
        <div className="scoreboard-header compact-header">
          <div className="scoreboard-title">{phaseText[phase] || phase}</div>
          <div className="round-indicator">Round {round}/{bestOf}</div>
        </div>
        <div className="compact-row">
          <div className="compact-side">
            <div className="compact-name p1">1P 多方</div>
            <div className="health-bar compact-bar">
              <div className="health-fill p1" style={{ width: `${p1Percent}%` }} />
            </div>
            <div className="compact-text">{p1Hp} | 胜 {p1Wins}</div>
          </div>
          <div className="vs-divider compact-vs">VS</div>
          <div className="compact-side">
            <div className="compact-name p2">2P 空方</div>
            <div className="health-bar compact-bar">
              <div className="health-fill p2" style={{ width: `${p2Percent}%` }} />
            </div>
            <div className="compact-text">{p2Hp} | 胜 {p2Wins}</div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="scoreboard">
      <div className="scoreboard-header">
        <div className="scoreboard-title">{phaseText[phase] || phase}</div>
        <div className="round-indicator">Round {round} / {bestOf}</div>
      </div>

      <div className="fighters-row">
        <div className="fighter-info">
          <div className="fighter-name p1">1P 多方</div>
          <div className="health-bar">
            <div className="health-fill p1" style={{ width: `${p1Percent}%` }} />
          </div>
          <div className="health-text">{Math.floor(p1Hp)} / {p1MaxHp} | 胜 {p1Wins}</div>
        </div>

        <div className="vs-divider">VS</div>

        <div className="fighter-info">
          <div className="fighter-name p2">2P 空方</div>
          <div className="health-bar">
            <div className="health-fill p2" style={{ width: `${p2Percent}%` }} />
          </div>
          <div className="health-text">{Math.floor(p2Hp)} / {p2MaxHp} | 胜 {p2Wins}</div>
        </div>
      </div>
    </div>
  );
}
