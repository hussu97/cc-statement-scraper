import { useMemo } from 'react';
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';

import { StackedSeriesResponse } from '../../types/dashboard';

const COLORS = ['#0f766e', '#1d4ed8', '#ea580c', '#be123c', '#7c3aed', '#2563eb', '#15803d', '#0891b2'];

export type StackedTrendClick = {
  bucket: string;
  seriesKey: string;
};

export function StackedTrendChart({
  data,
  mode,
  onPointClick,
}: {
  data: StackedSeriesResponse;
  mode: 'area' | 'bar' | 'line';
  onPointClick?: (value: StackedTrendClick) => void;
}) {
  const prepared = useMemo(() => {
    const seriesDefs = data.series.map((entry, index) => {
      const pointsByBucket = new Map(entry.points.map((point) => [point.bucket, point.value_aed]));
      return {
        label: entry.key,
        dataKey: `s_${index}`,
        color: COLORS[index % COLORS.length],
        pointsByBucket,
      };
    });

    const rows = data.buckets.map((bucket) => {
      const row: Record<string, number | string> = { bucket };
      for (const seriesDef of seriesDefs) {
        row[seriesDef.dataKey] = seriesDef.pointsByBucket.get(bucket) ?? 0;
      }
      return row;
    });

    return {
      rows,
      seriesDefs,
    };
  }, [data]);

  if (!prepared.rows.length || !prepared.seriesDefs.length) {
    return <p className="muted">No trend data available for the selected filters.</p>;
  }

  const tooltipStyle = {
    backgroundColor: '#fffef9',
    border: '1px solid #d6ddd1',
    borderRadius: '10px',
    boxShadow: '0 10px 22px rgba(17, 24, 24, 0.1)',
    opacity: 1,
  };

  function handlePointClick(row: unknown, seriesKey: string) {
    if (!onPointClick) {
      return;
    }
    const source = row as { bucket?: string; payload?: { bucket?: string } } | null;
    const bucket = String(source?.bucket || source?.payload?.bucket || '').trim();
    if (!bucket) {
      return;
    }
    onPointClick({ bucket, seriesKey });
  }

  return (
    <div className="chart-wrap">
      <ResponsiveContainer width="100%" height="100%">
        {mode === 'bar' ? (
          <BarChart data={prepared.rows}>
            <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
            <XAxis dataKey="bucket" />
            <YAxis />
            <Tooltip contentStyle={tooltipStyle} />
            <Legend />
            {prepared.seriesDefs.map((seriesDef) => (
              <Bar
                key={seriesDef.dataKey}
                dataKey={seriesDef.dataKey}
                name={seriesDef.label}
                fill={seriesDef.color}
                stackId="total"
                cursor={onPointClick ? 'pointer' : 'default'}
                onClick={(row) => handlePointClick(row, seriesDef.label)}
              />
            ))}
          </BarChart>
        ) : mode === 'line' ? (
          <LineChart data={prepared.rows}>
            <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
            <XAxis dataKey="bucket" />
            <YAxis />
            <Tooltip
              contentStyle={tooltipStyle}
              cursor={{ stroke: '#9fb0a8', strokeWidth: 1, fill: 'transparent' }}
            />
            <Legend />
            {prepared.seriesDefs.map((seriesDef) => (
              <Line
                key={seriesDef.dataKey}
                type="monotone"
                dataKey={seriesDef.dataKey}
                name={seriesDef.label}
                stroke={seriesDef.color}
                strokeWidth={2}
                dot={onPointClick ? { r: 3 } : false}
                activeDot={{ r: 5, cursor: onPointClick ? 'pointer' : 'default' }}
                cursor={onPointClick ? 'pointer' : 'default'}
                onClick={(row) => handlePointClick(row, seriesDef.label)}
              />
            ))}
          </LineChart>
        ) : (
          <AreaChart data={prepared.rows}>
            <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
            <XAxis dataKey="bucket" />
            <YAxis />
            <Tooltip contentStyle={tooltipStyle} />
            <Legend />
            {prepared.seriesDefs.map((seriesDef) => (
              <Area
                key={seriesDef.dataKey}
                type="monotone"
                dataKey={seriesDef.dataKey}
                name={seriesDef.label}
                fill={seriesDef.color}
                stroke={seriesDef.color}
                fillOpacity={0.35}
                stackId="total"
                cursor={onPointClick ? 'pointer' : 'default'}
                onClick={(row) => handlePointClick(row, seriesDef.label)}
              />
            ))}
          </AreaChart>
        )}
      </ResponsiveContainer>
    </div>
  );
}
