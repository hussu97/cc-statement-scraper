import { Cell, Legend, Pie, PieChart, ResponsiveContainer, Tooltip } from 'recharts';

import { BreakdownPoint } from '../../types/dashboard';

const COLORS = ['#0f766e', '#2563eb', '#f97316', '#be123c', '#7c3aed', '#14b8a6', '#6b7280'];

export function DonutBreakdownChart({ data }: { data: BreakdownPoint[] }) {
  const rows = data.filter((point) => point.value > 0);
  if (!rows.length) {
    return <p className="muted">No composition data for the selected filters.</p>;
  }

  return (
    <div className="chart-wrap chart-wrap-sm">
      <ResponsiveContainer width="100%" height="100%">
        <PieChart>
          <Pie data={rows} dataKey="value" nameKey="key" innerRadius={58} outerRadius={88} paddingAngle={2}>
            {rows.map((entry, index) => (
              <Cell key={entry.key} fill={COLORS[index % COLORS.length]} />
            ))}
          </Pie>
          <Tooltip />
          <Legend />
        </PieChart>
      </ResponsiveContainer>
    </div>
  );
}
