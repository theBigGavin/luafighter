
import { useState } from 'react';

interface EventLogProps {
  events: { time: string; message: string }[];
}

/**
 * 事件日志组件
 * 默认折叠，debug 时再展开
 */

export default function EventLog({ events }: EventLogProps) {
  const [expanded, setExpanded] = useState(false);

  return (
    <div className="panel">
      <div className="panel-title event-log-title">
        <span>事件日志 {events.length > 0 && `(${events.length})`}</span>
        <button
          className="event-log-toggle"
          onClick={() => setExpanded((prev) => !prev)}
          title={expanded ? '隐藏日志' : '显示日志'}
        >
          {expanded ? '隐藏' : '显示'}
        </button>
      </div>

      {expanded && (
        <div className="event-log">
          {events.length === 0 && (
            <div style={{ color: '#6b7280', padding: '8px 0', fontSize: 12 }}>
              等待事件...
            </div>
          )}
          {events.map((event, index) => (
            <div key={index} className="event-item">
              <span className="event-time">{event.time}</span>
              {event.message}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
