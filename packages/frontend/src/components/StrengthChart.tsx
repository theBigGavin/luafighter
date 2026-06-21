import { useEffect, useRef } from 'react';
import * as echarts from 'echarts';

interface StrengthChartProps {
  data: { time: number; value: number }[];
}

/**
 * 多空强度实时图表
 * 使用 ECharts 绘制强度指数曲线
 */

export default function StrengthChart({ data }: StrengthChartProps) {
  const chartRef = useRef<HTMLDivElement>(null);
  const chartInstance = useRef<echarts.ECharts | null>(null);

  useEffect(() => {
    if (!chartRef.current) return;

    if (!chartInstance.current) {
      chartInstance.current = echarts.init(chartRef.current, 'dark', {
        renderer: 'canvas',
      });
    }

    const chart = chartInstance.current;

    const xData = data.map((d) => new Date(d.time).toLocaleTimeString('zh-CN', { hour12: false }));
    const yData = data.map((d) => d.value);

    const option: echarts.EChartsOption = {
      backgroundColor: 'transparent',
      grid: {
        top: 10,
        right: 10,
        bottom: 20,
        left: 40,
      },
      tooltip: {
        trigger: 'axis',
        formatter: (params: any) => {
          const p = params[0];
          return `${p.name}<br/>强度: ${Number(p.value).toFixed(4)}`;
        },
      },
      xAxis: {
        type: 'category',
        data: xData,
        show: false,
      },
      yAxis: {
        type: 'value',
        min: -1,
        max: 1,
        splitLine: {
          lineStyle: { color: '#2a2d35' },
        },
        axisLabel: {
          color: '#6b7280',
          fontSize: 10,
          formatter: (value: number) => value.toFixed(1),
        },
      },
      series: [
        {
          type: 'line',
          data: yData,
          smooth: true,
          symbol: 'none',
          lineStyle: {
            width: 2,
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
              { offset: 0, color: '#ef4444' },
              { offset: 0.5, color: '#9ca3af' },
              { offset: 1, color: '#22c55e' },
            ]),
          },
          areaStyle: {
            color: new echarts.graphic.LinearGradient(0, 0, 0, 1, [
              { offset: 0, color: 'rgba(239, 68, 68, 0.1)' },
              { offset: 0.5, color: 'rgba(156, 163, 175, 0.05)' },
              { offset: 1, color: 'rgba(34, 197, 94, 0.1)' },
            ]),
          },
          markLine: {
            symbol: 'none',
            data: [{ yAxis: 0 }],
            lineStyle: {
              color: '#4b5563',
              width: 1,
              type: 'dashed',
            },
            label: { show: false },
          },
        },
      ],
    };

    chart.setOption(option);

    return () => {
      chart.dispose();
      chartInstance.current = null;
    };
  }, []);

  // 数据更新时只做增量更新，不销毁实例
  useEffect(() => {
    if (!chartInstance.current || data.length === 0) return;
    chartInstance.current.setOption({
      xAxis: {
        data: data.map((d) => new Date(d.time).toLocaleTimeString('zh-CN', { hour12: false })),
      },
      series: [{ data: data.map((d) => d.value) }],
    });
  }, [data]);

  return <div ref={chartRef} className="chart-container" />;
}
