import { useState, useEffect, useMemo } from 'react';
import { Link, useNavigate } from 'react-router-dom';

interface RoomItem {
  roomId: string;
  status: 'idle' | 'initializing' | 'running' | 'crashed' | 'stopped';
  rom: string;
  symbol: string;
  uptime: number;
}

const ROM_NAMES: Record<string, string> = {
  sf2: '街头霸王2',
  sf2ce: '超级街霸2X',
  kof97: '拳皇97',
};

const SYMBOL_NAMES: Record<string, string> = {
  IF2306: '沪深300期货',
  IC2306: '中证500期货',
  '000001.SZ': '平安银行',
};

/**
 * 房间列表页面
 */
export default function RoomList() {
  const [rooms, setRooms] = useState<RoomItem[]>([]);
  const [showModal, setShowModal] = useState(false);
  const [isCreating, setIsCreating] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);
  const [newRoom, setNewRoom] = useState({ rom: 'sf2ce', symbol: 'IF2306' });
  const [stopConfirmRoomId, setStopConfirmRoomId] = useState<string | null>(null);
  const [isStopping, setIsStopping] = useState(false);
  const [stopError, setStopError] = useState<string | null>(null);
  const navigate = useNavigate();

  useEffect(() => {
    fetchRooms();
    const interval = setInterval(fetchRooms, 3000);
    return () => clearInterval(interval);
  }, []);

  const fetchRooms = async () => {
    try {
      const res = await fetch('/api/rooms');
      const data = await res.json();
      setRooms(data.rooms || []);
    } catch (err) {
      console.error('获取房间列表失败:', err);
    }
  };

  const hasActiveRoom = useMemo(
    () => rooms.some((r) => r.status === 'running' || r.status === 'initializing'),
    [rooms]
  );

  const createRoom = async () => {
    if (isCreating) return;
    setIsCreating(true);
    setCreateError(null);
    try {
      const res = await fetch('/api/rooms', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(newRoom),
      });
      const data = await res.json();
      if (data.success) {
        setShowModal(false);
        navigate(`/room/${data.roomId}`);
      } else {
        setCreateError(data.error || '创建房间失败');
      }
    } catch (err) {
      setCreateError('网络错误，请重试');
    } finally {
      setIsCreating(false);
    }
  };

  const resetRoom = async (e: React.MouseEvent, roomId: string) => {
    e.preventDefault();
    e.stopPropagation();
    try {
      const res = await fetch(`/api/rooms/${roomId}/reset`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
      });
      const data = await res.json();
      if (data.success) {
        await fetchRooms();
      } else {
        alert('重置房间失败: ' + data.error);
      }
    } catch (err) {
      alert('重置房间失败');
    }
  };

  const stopRoom = (e: React.MouseEvent, roomId: string) => {
    e.preventDefault();
    e.stopPropagation();
    setStopError(null);
    setStopConfirmRoomId(roomId);
  };

  const confirmStopRoom = async () => {
    if (!stopConfirmRoomId) return;
    setIsStopping(true);
    setStopError(null);
    try {
      const res = await fetch(`/api/rooms/${stopConfirmRoomId}`, { method: 'DELETE' });
      const data = await res.json();
      if (data.success) {
        setStopConfirmRoomId(null);
        await fetchRooms();
      } else {
        setStopError(data.error || '结束房间失败');
      }
    } catch (err) {
      setStopError('网络错误，请重试');
    } finally {
      setIsStopping(false);
    }
  };

  const getRomName = (rom: string) => ROM_NAMES[rom] || rom;
  const getSymbolName = (symbol: string) => SYMBOL_NAMES[symbol] || symbol;

  const getStatusText = (status: RoomItem['status']) => {
    switch (status) {
      case 'running':
        return '进行中';
      case 'initializing':
        return '初始化中';
      case 'idle':
        return '空闲';
      default:
        return '异常';
    }
  };

  const canReset = (status: RoomItem['status']) =>
    status === 'crashed' || status === 'stopped' || status === 'idle';
  const canStop = (status: RoomItem['status']) =>
    status === 'running' || status === 'initializing';

  return (
    <div className="room-list-container">
      <div className="room-list-header">
        <h1>对战房间</h1>
        <button
          className="create-btn"
          onClick={() => {
            setCreateError(null);
            setShowModal(true);
          }}
          disabled={hasActiveRoom}
          title={hasActiveRoom ? '已有一个进行中的房间，请先结束' : '创建新房间'}
        >
          + 创建房间
        </button>
      </div>

      <div className="room-grid">
        {rooms.map((room) => (
          <div key={room.roomId} className="room-card">
            <Link to={`/room/${room.roomId}`} className="room-card-body">
              <div className="room-card-header">
                <span className="room-card-title">{room.roomId}</span>
                <span className={`room-status ${room.status}`}>
                  {getStatusText(room.status)}
                </span>
              </div>
              <div className="room-card-info">
                <div>🎮 {getRomName(room.rom)}</div>
                <div>📈 {getSymbolName(room.symbol)}</div>
                <div>⏱️ 运行 {formatUptime(room.uptime)}</div>
              </div>
            </Link>
            <div className="room-card-actions">
              {canStop(room.status) && (
                <button
                  className="stop-btn"
                  onClick={(e) => stopRoom(e, room.roomId)}
                  title="结束正在运行的房间"
                >
                  结束
                </button>
              )}
              {canReset(room.status) && (
                <button
                  className="reset-btn"
                  onClick={(e) => resetRoom(e, room.roomId)}
                  title="用相同配置重新启动"
                >
                  重置
                </button>
              )}
            </div>
          </div>
        ))}
        {rooms.length === 0 && (
          <div className="room-empty">
            暂无活跃房间，点击上方按钮创建
          </div>
        )}
      </div>

      {showModal && (
        <div className="modal-overlay" onClick={() => setShowModal(false)}>
          <div className="modal-content" onClick={(e) => e.stopPropagation()}>
            <h2>创建新房间</h2>
            <div className="form-group">
              <label>游戏</label>
              <select
                value={newRoom.rom}
                onChange={(e) => setNewRoom({ ...newRoom, rom: e.target.value })}
              >
                <option value="sf2">街头霸王2 (sf2)</option>
                <option value="sf2ce">超级街霸2X (sf2ce)</option>
                <option value="kof97">拳皇97 (kof97)</option>
              </select>
            </div>
            <div className="form-group">
              <label>行情标的</label>
              <select
                value={newRoom.symbol}
                onChange={(e) => setNewRoom({ ...newRoom, symbol: e.target.value })}
              >
                <option value="IF2306">IF2306 - 沪深300期货</option>
                <option value="IC2306">IC2306 - 中证500期货</option>
                <option value="000001.SZ">000001.SZ - 平安银行</option>
              </select>
            </div>

            {createError && <div className="modal-error">{createError}</div>}

            <div className="modal-actions">
              <button className="cancel-btn" onClick={() => setShowModal(false)} disabled={isCreating}>
                取消
              </button>
              <button
                className="confirm-btn"
                onClick={createRoom}
                disabled={isCreating || hasActiveRoom}
              >
                {isCreating ? '创建中...' : '创建'}
              </button>
            </div>
          </div>
        </div>
      )}

      {stopConfirmRoomId && (
        <div className="modal-overlay" onClick={() => setStopConfirmRoomId(null)}>
          <div className="modal-content" onClick={(e) => e.stopPropagation()}>
            <h2>结束房间</h2>
            <p className="modal-message">
              确定要结束房间 <strong>{stopConfirmRoomId}</strong> 吗？
              <br />
              结束后该房间将不可恢复。
            </p>
            {stopError && <div className="modal-error">{stopError}</div>}
            <div className="modal-actions">
              <button
                className="cancel-btn"
                onClick={() => setStopConfirmRoomId(null)}
                disabled={isStopping}
              >
                取消
              </button>
              <button
                className="confirm-btn danger"
                onClick={confirmStopRoom}
                disabled={isStopping}
              >
                {isStopping ? '结束中...' : '确认结束'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function formatUptime(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  if (m > 0) return `${m}分${s}秒`;
  return `${s}秒`;
}
