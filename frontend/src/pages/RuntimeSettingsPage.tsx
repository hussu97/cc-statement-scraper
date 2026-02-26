import { useEffect, useState } from 'react';

import { api } from '../api';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';
import { formatLocalDateTime } from '../utils/datetime';

type RuntimeSetting = {
  id: number;
  key: string;
  value: string;
  has_value: boolean;
  bank_code: string | null;
  is_secret: boolean;
  description: string | null;
  created_at: string;
  updated_at: string;
};

function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delayMs);
    return () => window.clearTimeout(timer);
  }, [delayMs, value]);

  return debounced;
}

export function RuntimeSettingsPage() {
  const activeProfileKey = useActiveProfileKey();
  const [rows, setRows] = useState<RuntimeSetting[]>([]);
  const [totalRows, setTotalRows] = useState(0);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(100);
  const [edits, setEdits] = useState<Record<string, string>>({});
  const [search, setSearch] = useState('');
  const debouncedSearch = useDebouncedValue(search, 300);
  const [showSecrets, setShowSecrets] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [newItem, setNewItem] = useState({
    key: '',
    value: '',
    bank_code: '',
    is_secret: true,
    description: '',
  });

  async function load(nextPage = page, nextPageSize = pageSize, nextSearch = debouncedSearch) {
    try {
      setError(null);
      setLoading(true);
      const params = new URLSearchParams();
      params.set('page', String(nextPage));
      params.set('page_size', String(nextPageSize));
      if (nextSearch.trim()) {
        params.set('search', nextSearch.trim());
      }
      const data = await api.get<any>(`/runtime-settings?${params.toString()}`);
      const nextTotal = Number(data.total || 0);
      setTotalRows(nextTotal);
      setRows(data.items || []);
      setEdits({});
      const totalPages = Math.max(1, Math.ceil(nextTotal / Math.max(nextPageSize, 1)));
      if (nextPage > totalPages) {
        setPage(totalPages);
      }
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }

  async function saveRow(row: RuntimeSetting) {
    try {
      setError(null);
      const hasEdit = Object.prototype.hasOwnProperty.call(edits, row.key);
      const payload: Record<string, unknown> = {
        bank_code: row.bank_code,
        is_secret: row.is_secret,
        description: row.description,
      };
      if (hasEdit) {
        payload.value = edits[row.key];
      }
      const updated = await api.patch<RuntimeSetting>(`/runtime-settings/${encodeURIComponent(row.key)}`, {
        ...payload,
      });
      setRows((prev) => prev.map((item) => (item.key === updated.key ? updated : item)));
      setEdits((prev) => {
        const next = { ...prev };
        delete next[row.key];
        return next;
      });
      setStatusMessage(`Saved ${row.key}`);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function createSetting() {
    if (!newItem.key.trim()) {
      setError('Key is required.');
      return;
    }
    try {
      setError(null);
      const created = await api.post<RuntimeSetting>('/runtime-settings', {
        key: newItem.key.trim(),
        value: newItem.value,
        bank_code: newItem.bank_code.trim() || null,
        is_secret: newItem.is_secret,
        description: newItem.description.trim() || null,
      });
      setNewItem({
        key: '',
        value: '',
        bank_code: '',
        is_secret: true,
        description: '',
      });
      setStatusMessage(`Saved ${created.key}`);
      setPage(1);
      await load(1, pageSize, debouncedSearch);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function seedFromEnv() {
    try {
      setError(null);
      const result = await api.post<any>('/runtime-settings/seed-from-env', { overwrite_existing: false });
      setStatusMessage(
        `Seeded from ${result.env_file}: inserted ${result.inserted}, updated ${result.updated}, skipped ${result.skipped}`,
      );
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
  }, [activeProfileKey, page, pageSize, debouncedSearch]);

  return (
    <div className="grid">
      <Panel title="Runtime Variables">
        <p className="muted">
          DB-backed runtime settings for bank scraping and parsing credentials. Updates apply to upcoming jobs without
          editing `.env`.
        </p>

        {error ? <p className="error" style={{ marginTop: '0.5rem' }}>{error}</p> : null}
        {statusMessage ? <p className="muted" style={{ marginTop: '0.5rem' }}>{statusMessage}</p> : null}
        {loading ? <p className="muted" style={{ marginTop: '0.5rem' }}>Loading runtime settings...</p> : null}

        <div className="row" style={{ marginTop: '0.75rem' }}>
          <input
            value={search}
            onChange={(event) => {
              setPage(1);
              setSearch(event.target.value);
            }}
            placeholder="Search key/bank/description"
          />
          <label style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
            <input
              type="checkbox"
              checked={showSecrets}
              onChange={(event) => setShowSecrets(event.target.checked)}
            />
            Show secrets
          </label>
          <button className="ghost" onClick={() => load()}>Refresh</button>
          <button className="ghost" onClick={seedFromEnv}>Seed from .env</button>
        </div>

        <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
          <table>
            <thead>
              <tr>
                <th>Key</th>
                <th>Bank</th>
                <th>Value</th>
                <th>Description</th>
                <th>Updated</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.id}>
                  <td><code>{row.key}</code></td>
                  <td>{row.bank_code || '-'}</td>
                  <td style={{ minWidth: '280px' }}>
                    {(() => {
                      const hasEdit = Object.prototype.hasOwnProperty.call(edits, row.key);
                      const inputValue = hasEdit ? edits[row.key] : row.value;
                      const hiddenSecretPlaceholder =
                        row.is_secret && row.has_value && !showSecrets && !hasEdit
                          ? 'Stored secret (hidden)'
                          : '';
                      return (
                    <input
                      type={row.is_secret && !showSecrets ? 'password' : 'text'}
                      value={inputValue}
                      onChange={(event) =>
                        setEdits((prev) => ({ ...prev, [row.key]: event.target.value }))
                      }
                      placeholder={hiddenSecretPlaceholder}
                      style={{ width: '100%' }}
                    />
                      );
                    })()}
                  </td>
                  <td>{row.description || '-'}</td>
                  <td>{formatLocalDateTime(row.updated_at)}</td>
                  <td>
                    <button className="primary" onClick={() => saveRow(row)}>Save</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <TablePagination
          page={page}
          pageSize={pageSize}
          total={totalRows}
          itemLabel="runtime settings"
          disabled={loading}
          onPageChange={setPage}
          onPageSizeChange={(next) => {
            setPageSize(next);
            setPage(1);
          }}
        />
      </Panel>

      <Panel title="Add Variable">
        <p className="muted">Add additional runtime variables needed by scrapers.</p>
        <div className="row" style={{ marginTop: '0.75rem' }}>
          <input
            value={newItem.key}
            onChange={(event) => setNewItem((prev) => ({ ...prev, key: event.target.value.toUpperCase() }))}
            placeholder="Key (e.g. FAB_USERNAME)"
          />
          <input
            type={newItem.is_secret && !showSecrets ? 'password' : 'text'}
            value={newItem.value}
            onChange={(event) => setNewItem((prev) => ({ ...prev, value: event.target.value }))}
            placeholder="Value"
          />
          <input
            value={newItem.bank_code}
            onChange={(event) => setNewItem((prev) => ({ ...prev, bank_code: event.target.value.toUpperCase() }))}
            placeholder="Bank code (optional)"
          />
          <input
            value={newItem.description}
            onChange={(event) => setNewItem((prev) => ({ ...prev, description: event.target.value }))}
            placeholder="Description (optional)"
          />
          <label style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
            <input
              type="checkbox"
              checked={newItem.is_secret}
              onChange={(event) => setNewItem((prev) => ({ ...prev, is_secret: event.target.checked }))}
            />
            Secret
          </label>
          <button className="primary" onClick={createSetting}>Save Variable</button>
        </div>
      </Panel>
    </div>
  );
}
