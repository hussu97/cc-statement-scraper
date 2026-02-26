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

export function StackedTrendChart({
  data,
  mode,
}: {
  data: StackedSeriesResponse;
  mode: 'area' | 'bar' | 'line';
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

  return (
    <div className="chart-wrap">
      <ResponsiveContainer width="100%" height="100%">
        {mode === 'bar' ? (
          <BarChart data={prepared.rows}>
            <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
            <XAxis dataKey="bucket" />
            <YAxis />
            <Tooltip />
            <Legend />
            {prepared.seriesDefs.map((seriesDef) => (
              <Bar
                key={seriesDef.dataKey}
                dataKey={seriesDef.dataKey}
                name={seriesDef.label}
                fill={seriesDef.color}
                stackId="total"
              />
            ))}
          </BarChart>
        ) : mode === 'line' ? (
          <LineChart data={prepared.rows}>
            <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
            <XAxis dataKey="bucket" />
            <YAxis />
            <Tooltip />
            <Legend />
            {prepared.seriesDefs.map((seriesDef) => (
              <Line
                key={seriesDef.dataKey}
                type="monotone"
                dataKey={seriesDef.dataKey}
                name={seriesDef.label}
                stroke={seriesDef.color}
                strokeWidth={2}
                dot={false}
              />
            ))}
          </LineChart>
        ) : (
          <AreaChart data={prepared.rows}>
            <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
            <XAxis dataKey="bucket" />
            <YAxis />
            <Tooltip />
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
              />
            ))}
          </AreaChart>
        )}
      </ResponsiveContainer>
    </div>
  );
}
