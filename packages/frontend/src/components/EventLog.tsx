
interface EventLogProps {
  events: { time: string; message: string }[];
}

/**
 * 事件日志组件
 * 显示游戏内的关键事件
 */

export default function EventLog({ events }: EventLogProps) {
  return (
    <div className="panel">
      <h3 className="panel-title">事件日志</h3>
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
    </div>
  );
}
