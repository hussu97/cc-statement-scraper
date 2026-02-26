import { Cell, Legend, Pie, PieChart, ResponsiveContainer, Tooltip } from 'recharts';

import { BreakdownPoint } from '../../types/dashboard';

const COLORS = ['#0f766e', '#2563eb', '#f97316', '#be123c', '#7c3aed', '#14b8a6', '#6b7280'];

export function DonutBreakdownChart({
  data,
  onSliceClick,
}: {
  data: BreakdownPoint[];
  onSliceClick?: (key: string) => void;
}) {
  const rows = data.filter((point) => point.value > 0);
  if (!rows.length) {
    return <p className="muted">No composition data for the selected filters.</p>;
  }

  function handleSliceClick(entry: unknown) {
    if (!onSliceClick) {
      return;
    }
    const key = String(((entry as { key?: string; name?: string } | null)?.key || (entry as { key?: string; name?: string } | null)?.name || '')).trim();
    if (!key) {
      return;
    }
    onSliceClick(key);
  }

  return (
    <div className="chart-wrap chart-wrap-sm">
      <ResponsiveContainer width="100%" height="100%">
        <PieChart>
          <Pie
            data={rows}
            dataKey="value"
            nameKey="key"
            innerRadius={58}
            outerRadius={88}
            paddingAngle={2}
            onClick={handleSliceClick}
          >
            {rows.map((entry, index) => (
              <Cell
                key={entry.key}
                fill={COLORS[index % COLORS.length]}
                style={onSliceClick ? { cursor: 'pointer' } : undefined}
              />
            ))}
          </Pie>
          <Tooltip />
          <Legend />
        </PieChart>
      </ResponsiveContainer>
    </div>
  );
}
