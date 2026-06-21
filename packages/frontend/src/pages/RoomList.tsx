import { useState, useEffect } from 'react';
import { Link, useNavigate } from 'react-router-dom';

interface RoomItem {
  roomId: string;
  rom: string;
  symbol: string;
  status: 'idle' | 'running' | 'crashed' | 'stopped';
  uptime: number;
}

/**
 * 房间列表页面
 */

export default function RoomList() {
  const [rooms, setRooms] = useState<RoomItem[]>([]);
  const [showModal, setShowModal] = useState(false);
  const [newRoom, setNewRoom] = useState({ rom: 'sf2', symbol: 'IF2306' });
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

  const createRoom = async () => {
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
        alert('创建房间失败: ' + data.error);
      }
    } catch (err) {
      alert('创建房间失败');
    }
  };

  const getRomName = (rom: string) => {
    const map: Record<string, string> = {
      sf2: '街头霸王2',
      sf2ce: '超级街霸2X',
      kof97: '拳皇97',
    };
    return map[rom] || rom;
  };

  const getSymbolName = (symbol: string) => {
    const map: Record<string, string> = {
      IF2306: '沪深300期货',
      IC2306: '中证500期货',
    };
    return map[symbol] || symbol;
  };

  return (
    <div className="room-list-container">
      <div className="room-list-header">
        <h1>对战房间</h1>
        <button className="create-btn" onClick={() => setShowModal(true)}>
          + 创建房间
        </button>
      </div>

      <div className="room-grid">
        {rooms.map((room) => (
          <Link to={`/room/${room.roomId}`} key={room.roomId} className="room-card">
            <div className="room-card-header">
              <span className="room-card-title">{room.roomId}</span>
              <span className={`room-status ${room.status}`}>
                {room.status === 'running' ? '进行中' : room.status === 'idle' ? '空闲' : '异常'}
              </span>
            </div>
            <div className="room-card-info">
              <div>🎮 {getRomName(room.rom)}</div>
              <div>📈 {getSymbolName(room.symbol)}</div>
              <div>⏱️ 运行 {formatUptime(room.uptime)}</div>
            </div>
          </Link>
        ))}
        {rooms.length === 0 && (
          <div className="room-card" style={{ opacity: 0.6, textAlign: 'center' }}>
            <div style={{ padding: '40px 0', color: '#6b7280' }}>
              暂无活跃房间，点击上方按钮创建
            </div>
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
            <div className="modal-actions">
              <button className="cancel-btn" onClick={() => setShowModal(false)}>
                取消
              </button>
              <button className="confirm-btn" onClick={createRoom}>
                创建
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
