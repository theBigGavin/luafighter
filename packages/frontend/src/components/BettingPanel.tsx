import { useState } from 'react';
import { BetSide, BetRecord } from '../hooks/useBetting';

interface BettingPanelProps {
  balance: number;
  records: BetRecord[];
  strengthIndex: number;
  currentRound: number;
  phase: string;
  onPlaceBet: (side: BetSide, amount: number) => boolean;
}

const AMOUNTS = [100, 500, 1000];

/**
 * 投注面板
 * 允许观众在每回合对战阶段下注 1P/2P 胜负
 */
export default function BettingPanel({
  balance,
  records,
  strengthIndex,
  currentRound,
  phase,
  onPlaceBet,
}: BettingPanelProps) {
  const [selectedAmount, setSelectedAmount] = useState(500);
  const [lastError, setLastError] = useState<string | null>(null);

  const canBet = phase === 'fighting' || phase === 'round_start';

  const handleBet = (side: BetSide) => {
    setLastError(null);
    if (!canBet) {
      setLastError('仅在对战阶段可下注');
      return;
    }
    const ok = onPlaceBet(side, selectedAmount);
    if (!ok) {
      setLastError('余额不足');
    }
  };

  const pendingRecords = records.filter((r) => r.status === 'pending');
  const settledRecords = records.filter((r) => r.status !== 'pending').slice(0, 5);

  return (
    <div className="panel betting-panel">
      <h3 className="panel-title">🎰 预测下注</h3>

      <div className="betting-balance">
        余额: <span className="balance-value">{balance.toLocaleString()}</span>
      </div>

      <div className="betting-amounts">
        {AMOUNTS.map((amount) => (
          <button
            key={amount}
            className={`amount-chip ${selectedAmount === amount ? 'active' : ''}`}
            onClick={() => setSelectedAmount(amount)}
          >
            {amount}
          </button>
        ))}
      </div>

      <div className="betting-actions">
        <button
          className="bet-btn p1"
          onClick={() => handleBet('p1')}
          disabled={!canBet || balance < selectedAmount}
        >
          <span className="bet-side">多方 1P 胜</span>
          <span className="bet-odds">赔率 {calculateOddsDisplay(strengthIndex, 'p1')}</span>
        </button>
        <button
          className="bet-btn p2"
          onClick={() => handleBet('p2')}
          disabled={!canBet || balance < selectedAmount}
        >
          <span className="bet-side">空方 2P 胜</span>
          <span className="bet-odds">赔率 {calculateOddsDisplay(strengthIndex, 'p2')}</span>
        </button>
      </div>

      {lastError && <div className="betting-error">{lastError}</div>}

      {pendingRecords.length > 0 && (
        <div className="betting-section">
          <h4>当前下注 (Round {currentRound})</h4>
          <ul className="betting-list">
            {pendingRecords.map((record) => (
              <li key={record.id} className="betting-item pending">
                <span>{record.side === 'p1' ? '多方 1P' : '空方 2P'}</span>
                <span>{record.amount} @ x{record.odds}</span>
              </li>
            ))}
          </ul>
        </div>
      )}

      {settledRecords.length > 0 && (
        <div className="betting-section">
          <h4>近期结算</h4>
          <ul className="betting-list">
            {settledRecords.map((record) => (
              <li key={record.id} className={`betting-item ${record.status}`}>
                <span>Round {record.round} {record.side === 'p1' ? '多方 1P' : '空方 2P'}</span>
                <span className={record.profit >= 0 ? 'profit-positive' : 'profit-negative'}>
                  {record.profit >= 0 ? '+' : ''}{record.profit}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

function calculateOddsDisplay(strengthIndex: number, side: BetSide): string {
  const s = Math.max(-1, Math.min(1, strengthIndex));
  if (side === 'p1') {
    return (1.5 + 1.5 * (1 - s) / 2).toFixed(2);
  }
  return (1.5 + 1.5 * (1 + s) / 2).toFixed(2);
}
