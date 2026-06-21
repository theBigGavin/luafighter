import { useState, useCallback, useRef } from 'react';

export type BetSide = 'p1' | 'p2';

export interface BetRecord {
  id: string;
  side: BetSide;
  amount: number;
  odds: number;
  round: number;
  status: 'pending' | 'win' | 'lose' | 'refund';
  profit: number;
}

export interface PlaceBetResult {
  success: boolean;
  error?: string;
}

interface RoundResult {
  winner: 1 | 2;
  round: number;
}

interface GameResult {
  winner: 1 | 2;
  p1Wins: number;
  p2Wins: number;
}

/**
 * 本地模拟投注状态管理
 * - 余额从 10000 开始
 * - 每回合只能下一单
 * - 赔率根据多空强度动态计算
 * - roundEnd / gameEnd 时结算当前 pending 投注
 */
export function useBetting(initialBalance = 10000) {
  const [balance, setBalance] = useState(initialBalance);
  const balanceRef = useRef(initialBalance);
  const [records, setRecords] = useState<BetRecord[]>([]);

  const syncBalance = useCallback((value: number) => {
    balanceRef.current = value;
    setBalance(value);
  }, []);

  /**
   * 根据多空强度计算赔率
   * strengthIndex: -1 ~ 1，正值表示多方（P1）优势
   */
  const calculateOdds = useCallback((strengthIndex: number, side: BetSide): number => {
    const s = Math.max(-1, Math.min(1, strengthIndex));
    if (side === 'p1') {
      return parseFloat((1.5 + 1.5 * (1 - s) / 2).toFixed(2));
    }
    return parseFloat((1.5 + 1.5 * (1 + s) / 2).toFixed(2));
  }, []);

  const placeBet = useCallback(
    (side: BetSide, amount: number, strengthIndex: number, round: number): PlaceBetResult => {
      if (amount <= 0) return { success: false, error: '投注金额无效' };
      if (amount > balanceRef.current) return { success: false, error: '余额不足' };

      // 每回合只能下一单
      const existingPending = records.find((r) => r.status === 'pending' && r.round === round);
      if (existingPending) {
        return { success: false, error: '本回合已下注' };
      }

      const odds = calculateOdds(strengthIndex, side);
      const newRecord: BetRecord = {
        id: `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
        side,
        amount,
        odds,
        round,
        status: 'pending',
        profit: 0,
      };

      const newBalance = balanceRef.current - amount;
      syncBalance(newBalance);
      setRecords((prev) => [newRecord, ...prev]);
      return { success: true };
    },
    [records, calculateOdds, syncBalance]
  );

  const settleRound = useCallback((result: RoundResult) => {
    let balanceDelta = 0;
    setRecords((prev) =>
      prev.map((bet) => {
        if (bet.status !== 'pending' || bet.round !== result.round) return bet;
        const won = (bet.side === 'p1' && result.winner === 1) || (bet.side === 'p2' && result.winner === 2);
        if (won) {
          const payout = Math.floor(bet.amount * bet.odds);
          balanceDelta += payout;
          return { ...bet, status: 'win', profit: payout - bet.amount };
        }
        return { ...bet, status: 'lose', profit: -bet.amount };
      })
    );
    if (balanceDelta !== 0) {
      syncBalance(balanceRef.current + balanceDelta);
    }
  }, [syncBalance]);

  const settleGame = useCallback((result: GameResult) => {
    let balanceDelta = 0;
    setRecords((prev) =>
      prev.map((bet) => {
        if (bet.status !== 'pending') return bet;
        const won = (bet.side === 'p1' && result.winner === 1) || (bet.side === 'p2' && result.winner === 2);
        if (won) {
          const payout = Math.floor(bet.amount * bet.odds);
          balanceDelta += payout;
          return { ...bet, status: 'win', profit: payout - bet.amount };
        }
        return { ...bet, status: 'lose', profit: -bet.amount };
      })
    );
    if (balanceDelta !== 0) {
      syncBalance(balanceRef.current + balanceDelta);
    }
  }, [syncBalance]);

  return {
    balance,
    records,
    placeBet,
    settleRound,
    settleGame,
    calculateOdds,
  };
}
