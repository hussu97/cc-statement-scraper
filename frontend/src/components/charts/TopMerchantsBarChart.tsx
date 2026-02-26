import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts';

import { BreakdownPoint } from '../../types/dashboard';

export function TopMerchantsBarChart({ data }: { data: BreakdownPoint[] }) {
  const rows = data.filter((point) => point.value > 0).slice(0, 10);

  if (!rows.length) {
    return <p className="muted">No merchant spend data for this selection.</p>;
  }

  return (
    <div className="chart-wrap chart-wrap-lg">
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={rows} layout="vertical" margin={{ left: 20 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
          <XAxis type="number" />
          <YAxis dataKey="key" type="category" width={180} />
          <Tooltip />
          <Bar dataKey="value" fill="#0f766e" radius={[0, 4, 4, 0]} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
