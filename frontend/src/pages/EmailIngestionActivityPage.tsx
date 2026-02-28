import { useEffect, useState } from 'react';

import { api } from '../api';
import { Panel } from '../components/Panel';
import { TablePagination } from '../components/TablePagination';
import { useActiveProfileKey } from '../profileStore';
import { formatLocalDateTime } from '../utils/datetime';

type EmailProvider = 'microsoft' | 'gmail';
type EmailIngestionStatus = 'queued' | 'uploaded' | 'duplicate' | 'ignored' | 'failed';

type PaginatedResponse<T> = {
  items: T[];
  total: number;
  page: number;
  page_size: number;
};

type BankOut = {
  code: string;
  name: string;
};

type EmailIngestionEventOut = {
  id: number;
  route_id: number;
  profile_id: number;
  bank_code: string;
  provider: EmailProvider;
  provider_message_id: string;
  provider_attachment_id: string;
  internet_message_id: string | null;
  attachment_filename: string;
  attachment_sha256: string;
  status: EmailIngestionStatus;
  upload_job_id: number | null;
  error_message: string | null;
  provider_received_at: string | null;
  processed_at: string | null;
  metadata_json: Record<string, unknown> | null;
  created_at: string;
};

function providerLabel(provider: EmailProvider): string {
  return provider === 'microsoft' ? 'Microsoft' : 'Gmail';
}

function fromDateTimeLocalInput(value: string): string | null {
  if (!value.trim()) {
    return null;
  }
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return null;
  }
  return parsed.toISOString();
}

export function EmailIngestionActivityPage() {
  const activeProfileKey = useActiveProfileKey();
  const [featureDisabled, setFeatureDisabled] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const [banks, setBanks] = useState<BankOut[]>([]);
  const [events, setEvents] = useState<EmailIngestionEventOut[]>([]);
  const [eventsTotal, setEventsTotal] = useState(0);
  const [eventsPage, setEventsPage] = useState(1);
  const [eventsPageSize, setEventsPageSize] = useState(100);

  const [filters, setFilters] = useState({
    bank_code: '',
    provider: '',
    status: '',
    search: '',
    created_from: '',
    created_to: '',
  });

  async function loadEvents(nextPage = eventsPage, nextPageSize = eventsPageSize) {
    try {
      setLoading(true);
      setError(null);
      const params = new URLSearchParams();
      params.set('page', String(nextPage));
      params.set('page_size', String(nextPageSize));
      if (filters.bank_code.trim()) {
        params.set('bank_code', filters.bank_code.trim().toUpperCase());
      }
      if (filters.provider.trim()) {
        params.set('provider', filters.provider.trim());
      }
      if (filters.status.trim()) {
        params.set('status', filters.status.trim());
      }
      if (filters.search.trim()) {
        params.set('search', filters.search.trim());
      }
      const createdFromIso = fromDateTimeLocalInput(filters.created_from);
      if (createdFromIso) {
        params.set('created_from', createdFromIso);
      }
      const createdToIso = fromDateTimeLocalInput(filters.created_to);
      if (createdToIso) {
        params.set('created_to', createdToIso);
      }
      const resp = await api.get<PaginatedResponse<EmailIngestionEventOut>>(
        `/email-ingestion/events?${params.toString()}`,
      );
      setEvents(resp.items);
      setEventsTotal(resp.total);
      setEventsPage(resp.page);
      setEventsPageSize(resp.page_size);
    } catch (loadError) {
      const message = (loadError as Error).message;
      if (message.includes('HTTP 404') && message.toLowerCase().includes('email ingestion')) {
        setFeatureDisabled(true);
        setError(null);
      } else {
        setError(message);
      }
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    api.get<BankOut[]>('/banks').then(setBanks).catch(() => {});
  }, []);

  useEffect(() => {
    setEventsPage(1);
  }, [activeProfileKey]);

  useEffect(() => {
    loadEvents(eventsPage, eventsPageSize);
  }, [activeProfileKey, eventsPage, eventsPageSize]);

  if (featureDisabled) {
    return (
      <div className="grid">
        <Panel title="Ingestion Activity">
          <p className="muted">
            Email ingestion is disabled for this environment. Enable{' '}
            <code>CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true</code> and reload the page.
          </p>
        </Panel>
      </div>
    );
  }

  return (
    <div className="grid">
      <Panel title="Ingestion Activity">
        <div className="row">
          <select
            value={filters.bank_code}
            onChange={(event) => {
              setFilters((prev) => ({ ...prev, bank_code: event.target.value }));
              setEventsPage(1);
            }}
          >
            <option value="">All banks</option>
            {banks.map((bank) => (
              <option key={bank.code} value={bank.code}>
                {bank.code}
              </option>
            ))}
          </select>
          <select
            value={filters.provider}
            onChange={(event) => {
              setFilters((prev) => ({ ...prev, provider: event.target.value }));
              setEventsPage(1);
            }}
          >
            <option value="">All providers</option>
            <option value="microsoft">Microsoft</option>
            <option value="gmail">Gmail</option>
          </select>
          <select
            value={filters.status}
            onChange={(event) => {
              setFilters((prev) => ({ ...prev, status: event.target.value }));
              setEventsPage(1);
            }}
          >
            <option value="">All statuses</option>
            <option value="queued">queued</option>
            <option value="uploaded">uploaded</option>
            <option value="duplicate">duplicate</option>
            <option value="ignored">ignored</option>
            <option value="failed">failed</option>
          </select>
          <input
            value={filters.search}
            onChange={(event) => {
              setFilters((prev) => ({ ...prev, search: event.target.value }));
              setEventsPage(1);
            }}
            placeholder="Search attachment / message id"
          />
          <label style={{ display: 'inline-grid', gap: '0.2rem' }}>
            <span className="muted">From</span>
            <input
              type="datetime-local"
              value={filters.created_from}
              onChange={(event) => {
                setFilters((prev) => ({ ...prev, created_from: event.target.value }));
                setEventsPage(1);
              }}
            />
          </label>
          <label style={{ display: 'inline-grid', gap: '0.2rem' }}>
            <span className="muted">To</span>
            <input
              type="datetime-local"
              value={filters.created_to}
              onChange={(event) => {
                setFilters((prev) => ({ ...prev, created_to: event.target.value }));
                setEventsPage(1);
              }}
            />
          </label>
          <button className="ghost" onClick={() => loadEvents(1, eventsPageSize)}>
            Apply Filters
          </button>
          <button className="ghost" onClick={() => loadEvents(eventsPage, eventsPageSize)}>
            Refresh
          </button>
        </div>

        {error ? <p className="error" style={{ marginTop: '0.55rem' }}>{error}</p> : null}
        {loading ? <p className="muted" style={{ marginTop: '0.55rem' }}>Loading ingestion events...</p> : null}

        <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
          <table>
            <thead>
              <tr>
                <th>Created</th>
                <th>Bank</th>
                <th>Provider</th>
                <th>Status</th>
                <th>Attachment</th>
                <th>Message</th>
                <th>Upload Job</th>
                <th>Error</th>
              </tr>
            </thead>
            <tbody>
              {events.map((item) => (
                <tr key={item.id}>
                  <td>{formatLocalDateTime(item.created_at)}</td>
                  <td>{item.bank_code}</td>
                  <td>{providerLabel(item.provider)}</td>
                  <td>{item.status}</td>
                  <td>
                    <div>{item.attachment_filename}</div>
                    <div className="muted">{item.attachment_sha256.slice(0, 14)}...</div>
                  </td>
                  <td>
                    <div title={item.provider_message_id}>{item.provider_message_id.slice(0, 18)}...</div>
                    <div className="muted" title={item.provider_attachment_id}>
                      {item.provider_attachment_id.slice(0, 18)}...
                    </div>
                  </td>
                  <td>{item.upload_job_id || '-'}</td>
                  <td title={item.error_message || ''}>{item.error_message || '-'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <TablePagination
          page={eventsPage}
          pageSize={eventsPageSize}
          total={eventsTotal}
          itemLabel="events"
          disabled={loading}
          onPageChange={setEventsPage}
          onPageSizeChange={(nextPageSize) => {
            setEventsPageSize(nextPageSize);
            setEventsPage(1);
          }}
        />
      </Panel>
    </div>
  );
}
