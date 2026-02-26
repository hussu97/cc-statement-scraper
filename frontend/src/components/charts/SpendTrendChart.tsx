import {
  Bar,
  CartesianGrid,
  Legend,
  BarChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';

import { TrendPoint } from '../../types/dashboard';

export type SpendTrendClick = {
  bucket: string;
  seriesKey: 'debit' | 'credit';
};

export function SpendTrendChart({
  points,
  onBarClick,
}: {
  points: TrendPoint[];
  onBarClick?: (value: SpendTrendClick) => void;
}) {
  if (!points.length) {
    return <p className="muted">No trend data available for the selected filters.</p>;
  }

  function handleBarClick(row: unknown, seriesKey: SpendTrendClick['seriesKey']) {
    if (!onBarClick) {
      return;
    }
    const bucket = String((row as { bucket?: string } | null)?.bucket || '').trim();
    if (!bucket) {
      return;
    }
    onBarClick({ bucket, seriesKey });
  }

  return (
    <div className="chart-wrap">
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={points} barCategoryGap="22%" barGap={4}>
          <CartesianGrid strokeDasharray="3 3" stroke="#d5ddd3" />
          <XAxis dataKey="bucket" />
          <YAxis />
          <Tooltip />
          <Legend />
          <Bar
            dataKey="debit_aed"
            name="Debit"
            fill="#0f766e"
            radius={[4, 4, 0, 0]}
            cursor={onBarClick ? 'pointer' : 'default'}
            onClick={(row) => handleBarClick(row, 'debit')}
          />
          <Bar
            dataKey="credit_aed"
            name="Credit"
            fill="#f97316"
            radius={[4, 4, 0, 0]}
            cursor={onBarClick ? 'pointer' : 'default'}
            onClick={(row) => handleBarClick(row, 'credit')}
          />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
