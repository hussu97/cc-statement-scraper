import { useEffect, useState } from 'react';

import { api } from '../api';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';
import { formatLocalDateTime } from '../utils/datetime';
import type { PagedResponse, Schedule } from '../types/statements';

function currentDubaiMonthToken(): string {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Dubai',
    year: 'numeric',
    month: '2-digit',
  }).formatToParts(new Date());

  const year = parts.find((part) => part.type === 'year')?.value ?? String(new Date().getFullYear());
  const month = parts.find((part) => part.type === 'month')?.value ?? String(new Date().getMonth() + 1).padStart(2, '0');
  return `${year}-${month}`;
}

export function SchedulesPage() {
  const activeProfileKey = useActiveProfileKey();
  const defaultMonth = currentDubaiMonthToken();
  const [schedules, setSchedules] = useState<Schedule[]>([]);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(100);
  const [total, setTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({
    name: 'Monthly scrape',
    job_type: 'scrape',
    rrule: 'FREQ=WEEKLY;BYDAY=MO;BYHOUR=19;BYMINUTE=0',
    timezone: 'Asia/Dubai',
    status: 'active',
    payload_json: `{"banks":["FAB","ADCB","ENBD","SIB"],"month_from":"${defaultMonth}","month_to":"${defaultMonth}","download":true,"headless":false,"login_timeout_minutes":20}`,
  });

  async function load() {
    try {
      setError(null);
      const params = new URLSearchParams();
      params.set('page', String(page));
      params.set('page_size', String(pageSize));
      const data = await api.get<PagedResponse<Schedule>>(`/schedules?${params.toString()}`);
      const nextTotal = Number(data.total || 0);
      setTotal(nextTotal);
      setSchedules(data.items || []);
      const totalPages = Math.max(1, Math.ceil(nextTotal / Math.max(pageSize, 1)));
      if (page > totalPages) {
        setPage(totalPages);
      }
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function createSchedule() {
    try {
      const payload = {
        ...form,
        payload_json: JSON.parse(form.payload_json),
      };
      await api.post('/schedules', payload);
      await load();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function toggle(schedule: Schedule) {
    const status = schedule.status === 'active' ? 'paused' : 'active';
    try {
      await api.patch(`/schedules/${schedule.id}`, { status });
      await load();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function remove(scheduleId: number) {
    try {
      await api.delete(`/schedules/${scheduleId}`);
      await load();
    } catch (err) {
      setError((err as Error).message);
    }
  }

  useEffect(() => {
    setPage(1);
  }, [activeProfileKey]);

  useEffect(() => {
    load();
  }, [activeProfileKey, page, pageSize]);

  return (
    <div className="grid">
      <Panel title="Create Schedule">
        {error && <p className="error">{error}</p>}
        <div className="row">
          <input value={form.name} onChange={(e) => setForm((p) => ({ ...p, name: e.target.value }))} placeholder="Name" />
          <input value={form.rrule} onChange={(e) => setForm((p) => ({ ...p, rrule: e.target.value }))} placeholder="RRULE" />
          <input value={form.timezone} onChange={(e) => setForm((p) => ({ ...p, timezone: e.target.value }))} placeholder="Timezone" />
          <select value={form.status} onChange={(e) => setForm((p) => ({ ...p, status: e.target.value }))}>
            <option value="active">active</option>
            <option value="paused">paused</option>
          </select>
          <button className="primary" onClick={createSchedule}>Create</button>
        </div>
        <textarea
          value={form.payload_json}
          onChange={(e) => setForm((p) => ({ ...p, payload_json: e.target.value }))}
          rows={4}
          style={{ width: '100%', marginTop: '0.6rem' }}
        />
      </Panel>

      <Panel title="Schedules">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Name</th>
                <th>Status</th>
                <th>RRULE</th>
                <th>Next Run</th>
                <th>Last Run</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {schedules.map((item) => (
                <tr key={item.id}>
                  <td>{item.id}</td>
                  <td>{item.name}</td>
                  <td>{item.status}</td>
                  <td>{item.rrule}</td>
                  <td>{formatLocalDateTime(item.next_run_at)}</td>
                  <td>{formatLocalDateTime(item.last_run_at)}</td>
                  <td>
                    <button className="ghost" onClick={() => toggle(item)}>
                      {item.status === 'active' ? 'Pause' : 'Activate'}
                    </button>{' '}
                    <button className="ghost" onClick={() => remove(item.id)}>Delete</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <TablePagination
          page={page}
          pageSize={pageSize}
          total={total}
          itemLabel="schedules"
          onPageChange={setPage}
          onPageSizeChange={(next) => {
            setPageSize(next);
            setPage(1);
          }}
        />
      </Panel>
    </div>
  );
}
