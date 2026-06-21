import { BrowserRouter as Router, Routes, Route, Link } from 'react-router-dom';
import RoomList from './pages/RoomList';
import WatchRoom from './pages/WatchRoom';
import './App.css';

/**
 * 主应用组件
 */

function App() {
  return (
    <Router>
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
        <main className="app-main">
          <Routes>
            <Route path="/" element={<RoomList />} />
            <Route path="/room/:roomId" element={<WatchRoom />} />
          </Routes>
        </main>
      </div>
    </Router>
  );
}

export default App;
