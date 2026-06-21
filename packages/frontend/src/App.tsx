import { BrowserRouter as Router, Routes, Route, Link, useLocation } from 'react-router-dom';
import RoomList from './pages/RoomList';
import WatchRoom from './pages/WatchRoom';
import './App.css';

/**
 * 主应用组件
 */
function AppContent() {
  const location = useLocation();
  const isWatchMode = location.pathname.startsWith('/room');

  return (
    <div className="app">
      <header className="app-header">
        <Link to="/" className="logo">
          <span className="logo-icon">🥊</span>
          <span className="logo-text">LuaFighter</span>
        </Link>
        <nav className="nav-links">
          <Link to="/">房间列表</Link>
        </nav>
      </header>
      <main className={`app-main ${isWatchMode ? 'watch-mode' : ''}`}>
        <Routes>
          <Route path="/" element={<RoomList />} />
          <Route path="/room/:roomId" element={<WatchRoom />} />
        </Routes>
      </main>
    </div>
  );
}

function App() {
  return (
    <Router>
      <AppContent />
    </Router>
  );
}

export default App;
