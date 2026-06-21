import { useState } from 'react';
import { BetSide, BetRecord, PlaceBetResult } from '../hooks/useBetting';

interface BettingPanelProps {
  balance: number;
  records: BetRecord[];
  strengthIndex: number;
  currentRound: number;
  phase: string;
  onPlaceBet: (side: BetSide, amount: number) => PlaceBetResult;
}

const AMOUNTS = [100, 500, 1000];

/**
 * 投注面板
 * 选择金额 + 方向后，点击「下单」下注
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
  const [selectedSide, setSelectedSide] = useState<BetSide | null>(null);
  const [message, setMessage] = useState<{ type: 'success' | 'error'; text: string } | null>(null);

  const canBet = phase === 'fighting' || phase === 'round_start';
  const pendingRecord = records.find((r) => r.status === 'pending' && r.round === currentRound);
  const alreadyBet = !!pendingRecord;

  const handlePlaceOrder = () => {
    setMessage(null);
    if (!canBet) {
      setMessage({ type: 'error', text: '仅在对战阶段可下注' });
      return;
    }
    if (alreadyBet) {
      setMessage({ type: 'error', text: '本回合已下注' });
      return;
    }
    if (!selectedSide) {
      setMessage({ type: 'error', text: '请选择下注方向' });
      return;
    }
    const result = onPlaceBet(selectedSide, selectedAmount);
    if (result.success) {
      setMessage({ type: 'success', text: `已下注 ${selectedAmount} 押${selectedSide === 'p1' ? '多方' : '空方'}` });
    } else {
      setMessage({ type: 'error', text: result.error || '下注失败' });
    }
  };

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
          className={`bet-btn p1 ${selectedSide === 'p1' ? 'selected' : ''}`}
          onClick={() => setSelectedSide('p1')}
          disabled={!canBet || alreadyBet}
        >
          <span className="bet-side">多方 1P 胜</span>
          <span className="bet-odds">赔率 {calculateOddsDisplay(strengthIndex, 'p1')}</span>
        </button>
        <button
          className={`bet-btn p2 ${selectedSide === 'p2' ? 'selected' : ''}`}
          onClick={() => setSelectedSide('p2')}
          disabled={!canBet || alreadyBet}
        >
          <span className="bet-side">空方 2P 胜</span>
          <span className="bet-odds">赔率 {calculateOddsDisplay(strengthIndex, 'p2')}</span>
        </button>
      </div>

      <button
        className="order-btn"
        onClick={handlePlaceOrder}
        disabled={!canBet || alreadyBet || balance < selectedAmount}
      >
        {alreadyBet ? '本回合已下注' : canBet ? '下单' : '非对战阶段'}
      </button>

      {message && (
        <div className={`betting-message ${message.type}`}>{message.text}</div>
      )}

      {pendingRecord && (
        <div className="betting-section">
          <h4>当前下注 (Round {currentRound})</h4>
          <ul className="betting-list">
            <li className="betting-item pending">
              <span>{pendingRecord.side === 'p1' ? '多方 1P' : '空方 2P'}</span>
              <span>{pendingRecord.amount} @ x{pendingRecord.odds}</span>
            </li>
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
