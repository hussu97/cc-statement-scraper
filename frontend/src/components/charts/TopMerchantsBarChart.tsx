import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';

import { BreakdownPoint } from '../../types/dashboard';

export function TopMerchantsBarChart({
  data,
  color = '#0f766e',
  emptyMessage = 'No merchant spend data for this selection.',
  maxItems = 10,
  onBarClick,
}: {
  data: BreakdownPoint[];
  color?: string;
  emptyMessage?: string;
  maxItems?: number;
  onBarClick?: (value: BreakdownPoint) => void;
}) {
  const rows = data.filter((point) => point.value > 0).slice(0, maxItems);

  if (!rows.length) {
    return <p className="muted">{emptyMessage}</p>;
  }

  function handleBarClick(row: unknown) {
    if (!onBarClick) {
      return;
    }
    const point = row as { key?: string; value?: number } | null;
    const key = String(point?.key || '').trim();
    if (!key) {
      return;
    }
    onBarClick({ key, value: Number(point?.value || 0) });
  }

  return (
    <div className="chart-wrap chart-wrap-lg">
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={rows} layout="vertical" margin={{ left: 20 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
          <XAxis type="number" />
          <YAxis dataKey="key" type="category" width={180} />
          <Tooltip />
          <Bar
            dataKey="value"
            fill={color}
            radius={[0, 4, 4, 0]}
            cursor={onBarClick ? 'pointer' : 'default'}
            onClick={handleBarClick}
          />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
