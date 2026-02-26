import { useEffect, useState } from 'react';

import { api } from '../api';
import { DateRangeField } from '../components/DateRangeField';
import { MultiSelectDropdown } from '../components/MultiSelectDropdown';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';
import { DashboardFilterMeta } from '../types/dashboard';

const EMPTY_FILTER_META: DashboardFilterMeta = {
  banks: [],
  categories: [],
  min_date: null,
  max_date: null,
};

type RawLineFilters = {
  merchantSearch: string;
  bankCodes: string[];
  categories: string[];
  dateFrom: string;
  dateTo: string;
  direction: '' | 'debit' | 'credit';
};

function useDebouncedValue<T>(value: T, delayMs: number): T {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = window.setTimeout(() => setDebounced(value), delayMs);
    return () => window.clearTimeout(timer);
  }, [delayMs, value]);

  return debounced;
}

function formatAmount(value: number): string {
  return new Intl.NumberFormat('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value);
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError';
}

export function RawLinesPage() {
  const activeProfileKey = useActiveProfileKey();
  const [filters, setFilters] = useState<RawLineFilters>({
    merchantSearch: '',
    bankCodes: [],
    categories: [],
    dateFrom: '',
    dateTo: '',
    direction: '',
  });
  const [rows, setRows] = useState<any[]>([]);
  const [filterMeta, setFilterMeta] = useState<DashboardFilterMeta>(EMPTY_FILTER_META);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(100);
  const [totalRows, setTotalRows] = useState(0);
  const [filteredAmountTotal, setFilteredAmountTotal] = useState(0);
  const [categoryPatch, setCategoryPatch] = useState<Record<number, string>>({});
  const debouncedMerchantSearch = useDebouncedValue(filters.merchantSearch, 300);

  async function loadFilterMeta() {
    try {
      const meta = await api.get<DashboardFilterMeta>('/dashboard/filter-meta');
      setFilterMeta(meta);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function search(signal?: AbortSignal) {
    try {
      setError(null);
      setLoading(true);
      const params = new URLSearchParams();

      const merchantSearch = debouncedMerchantSearch.trim();
      if (merchantSearch) {
        params.set('merchant_search', merchantSearch);
      }
      filters.bankCodes.forEach((code) => params.append('bank_codes', code.toUpperCase()));
      filters.categories.forEach((category) => params.append('categories', category));
      if (filters.dateFrom) {
        params.set('date_from', filters.dateFrom);
      }
      if (filters.dateTo) {
        params.set('date_to', filters.dateTo);
      }
      if (filters.direction) {
        params.set('direction', filters.direction);
      }
      params.set('page', String(page));
      params.set('page_size', String(pageSize));
      const data = await api.get<any>(`/transactions?${params.toString()}`, { signal });
      const total = Number(data.total || 0);
      setTotalRows(total);
      setFilteredAmountTotal(Number(data.filtered_amount_aed_sum || 0));
      setRows(data.items || []);
      const totalPages = Math.max(1, Math.ceil(total / Math.max(pageSize, 1)));
      if (page > totalPages) {
        setPage(totalPages);
      }
    } catch (err) {
      if (isAbortError(err)) {
        return;
      }
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }

  async function patchCategory(lineId: number) {
    const category = (categoryPatch[lineId] || '').trim();
    if (!category) {
      return;
    }

    try {
      await api.patch(`/transactions/${lineId}`, { category });
      setRows((prev) => prev.map((row) => (row.id === lineId ? { ...row, category } : row)));
    } catch (err) {
      setError((err as Error).message);
    }
  }

  useEffect(() => {
    loadFilterMeta();
    setPage(1);
  }, [activeProfileKey]);

  useEffect(() => {
    const controller = new AbortController();
    search(controller.signal);
    return () => controller.abort();
  }, [
    activeProfileKey,
    filters.bankCodes,
    filters.categories,
    filters.dateFrom,
    filters.dateTo,
    filters.direction,
    debouncedMerchantSearch,
    page,
    pageSize,
  ]);

  const rowCount = totalRows;

  return (
    <div className="grid">
      <Panel title="Raw Statement Lines">
        <p className="muted">Unified line-level view with searchable and filterable transactions across all banks.</p>
        {error && <p className="error">{error}</p>}
        {loading && <p className="muted">Loading lines...</p>}

        <div className="dashboard-filters" style={{ marginTop: '0.75rem' }}>
          <DateRangeField
            idPrefix="raw-lines-date-range"
            label="Transaction Date Range"
            value={{ from: filters.dateFrom, to: filters.dateTo }}
            min={filterMeta.min_date}
            max={filterMeta.max_date}
            onChange={(range) => {
              setPage(1);
              setFilters((prev) => ({ ...prev, dateFrom: range.from, dateTo: range.to }));
            }}
          />

          <MultiSelectDropdown
            id="raw-lines-banks"
            label="Banks"
            options={filterMeta.banks}
            value={filters.bankCodes}
            placeholder="All banks"
            onChange={(bankCodes) => {
              setPage(1);
              setFilters((prev) => ({ ...prev, bankCodes }));
            }}
          />

          <MultiSelectDropdown
            id="raw-lines-categories"
            label="Categories"
            options={filterMeta.categories}
            value={filters.categories}
            placeholder="All categories"
            onChange={(categories) => {
              setPage(1);
              setFilters((prev) => ({ ...prev, categories }));
            }}
          />

          <div className="filter-field">
            <label htmlFor="raw-lines-direction">Direction</label>
            <select
              id="raw-lines-direction"
              value={filters.direction}
              onChange={(event) =>
                {
                  setPage(1);
                  setFilters((prev) => ({
                    ...prev,
                    direction: event.target.value as '' | 'debit' | 'credit',
                  }));
                }
              }
            >
              <option value="">All Directions</option>
              <option value="debit">Debit</option>
              <option value="credit">Credit</option>
            </select>
          </div>

          <div className="filter-field filter-search">
            <label htmlFor="raw-lines-merchant-search">Merchant Search</label>
            <input
              id="raw-lines-merchant-search"
              value={filters.merchantSearch}
              onChange={(event) => {
                setPage(1);
                setFilters((prev) => ({ ...prev, merchantSearch: event.target.value }));
              }}
              placeholder="Search merchant text"
            />
          </div>
        </div>

        <p className="muted" style={{ marginTop: '0.5rem' }}>
          Showing {rows.length} line(s) on this page
        </p>

        <section className="kpi-grid" style={{ marginTop: '0.75rem', marginBottom: '0.75rem' }}>
          <article className="kpi-card">
            <span className="kpi-label">Amount AED Sum (filtered)</span>
            <strong className="kpi-value">AED {formatAmount(filteredAmountTotal)}</strong>
          </article>
          <article className="kpi-card">
            <span className="kpi-label">ID Count (filtered)</span>
            <strong className="kpi-value">{rowCount}</strong>
          </article>
        </section>

        <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Date</th>
                <th>Bank</th>
                <th>Merchant</th>
                <th>Amount AED</th>
                <th>Direction</th>
                <th>Category</th>
                <th>Quick Edit</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.id}>
                  <td>{row.id}</td>
                  <td>{row.transaction_date}</td>
                  <td>{row.bank_code}</td>
                  <td>{row.merchant_normalized}</td>
                  <td>{row.amount_aed}</td>
                  <td>{row.direction}</td>
                  <td>{row.category}</td>
                  <td>
                    <div className="row" style={{ flexWrap: 'nowrap' }}>
                      <input
                        value={categoryPatch[row.id] ?? row.category}
                        onChange={(event) =>
                          setCategoryPatch((prev) => ({ ...prev, [row.id]: event.target.value }))
                        }
                        style={{ width: '160px' }}
                      />
                      <button className="ghost" onClick={() => patchCategory(row.id)}>Save</button>
                    </div>
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
          itemLabel="lines"
          disabled={loading}
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
