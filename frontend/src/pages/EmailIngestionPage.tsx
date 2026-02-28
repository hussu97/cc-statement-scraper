import { useEffect, useMemo, useState } from 'react';

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

type RuntimeSetting = {
  key: string;
  value: string;
  has_value: boolean;
  is_secret: boolean;
};

type EmailMailboxOut = {
  id: number;
  profile_id: number;
  provider: EmailProvider;
  mailbox_email: string;
  display_name: string | null;
  is_active: boolean;
  sync_state_json: Record<string, unknown> | null;
  watch_expiration_at: string | null;
  last_sync_at: string | null;
  last_error_at: string | null;
  last_error_message: string | null;
  created_at: string;
  updated_at: string;
};

type EmailBankRouteOut = {
  id: number;
  profile_id: number;
  bank_code: string;
  mailbox_id: number;
  provider: EmailProvider;
  mailbox_email: string;
  sender_allowlist_json: string[] | null;
  subject_keywords_json: string[] | null;
  attachment_filename_regex: string | null;
  gmail_label_filter_json: Record<string, unknown> | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
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

type ServiceApiTokenOut = {
  id: number;
  profile_id: number;
  name: string;
  token_prefix: string;
  scopes_json: string[] | null;
  is_active: boolean;
  last_used_at: string | null;
  created_at: string;
  revoked_at: string | null;
};

type ServiceApiTokenCreated = {
  token: string;
  item: ServiceApiTokenOut;
};

type BankOut = {
  code: string;
  name: string;
};

type MailboxEditState = {
  mailbox_email: string;
  display_name: string;
  is_active: boolean;
};

type RouteFormState = {
  mailbox_id: string;
  sender_allowlist: string;
  subject_keywords: string;
  attachment_filename_regex: string;
  gmail_label_filter_json: string;
  is_active: boolean;
};

const SERVICE_SCOPE_OPTIONS = [
  'email_ingestion:read',
  'email_ingestion:write',
  'email_ingestion:upload',
] as const;

function providerLabel(provider: EmailProvider): string {
  return provider === 'microsoft' ? 'Microsoft' : 'Gmail';
}

function toCsv(values: string[] | null | undefined): string {
  if (!values || values.length === 0) {
    return '';
  }
  return values.join(', ');
}

function fromCsv(value: string): string[] | null {
  const tokens = value
    .split(',')
    .map((token) => token.trim())
    .filter(Boolean);
  return tokens.length > 0 ? tokens : null;
}

function toJsonInput(value: Record<string, unknown> | null | undefined): string {
  if (!value) {
    return '';
  }
  return JSON.stringify(value);
}

function toDateTimeLocalInput(value: string): string {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) {
    return '';
  }
  const pad = (num: number) => String(num).padStart(2, '0');
  const year = parsed.getFullYear();
  const month = pad(parsed.getMonth() + 1);
  const day = pad(parsed.getDate());
  const hours = pad(parsed.getHours());
  const minutes = pad(parsed.getMinutes());
  return `${year}-${month}-${day}T${hours}:${minutes}`;
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

export function EmailIngestionPage() {
  const activeProfileKey = useActiveProfileKey();
  const [featureDisabled, setFeatureDisabled] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [loadingConfig, setLoadingConfig] = useState(false);
  const [loadingEvents, setLoadingEvents] = useState(false);

  const [banks, setBanks] = useState<BankOut[]>([]);
  const [mailboxes, setMailboxes] = useState<EmailMailboxOut[]>([]);
  const [routes, setRoutes] = useState<EmailBankRouteOut[]>([]);
  const [mailboxEdits, setMailboxEdits] = useState<Record<number, MailboxEditState>>({});
  const [routeForms, setRouteForms] = useState<Record<string, RouteFormState>>({});
  const [runtimeByKey, setRuntimeByKey] = useState<Record<string, RuntimeSetting>>({});
  const [serviceTokens, setServiceTokens] = useState<ServiceApiTokenOut[]>([]);
  const [createdServiceToken, setCreatedServiceToken] = useState<string | null>(null);

  const [events, setEvents] = useState<EmailIngestionEventOut[]>([]);
  const [eventsTotal, setEventsTotal] = useState(0);
  const [eventsPage, setEventsPage] = useState(1);
  const [eventsPageSize, setEventsPageSize] = useState(100);

  const [createMailboxForm, setCreateMailboxForm] = useState({
    provider: 'microsoft' as EmailProvider,
    mailbox_email: '',
    display_name: '',
    is_active: true,
  });

  const [oauthForm, setOauthForm] = useState({
    microsoft_client_id: '',
    microsoft_client_secret: '',
    gmail_client_id: '',
    gmail_client_secret: '',
  });
  const [refreshTokensByMailbox, setRefreshTokensByMailbox] = useState<Record<number, string>>({});

  const [createTokenForm, setCreateTokenForm] = useState({
    name: '',
    scopes: [...SERVICE_SCOPE_OPTIONS] as string[],
  });

  const [eventFilters, setEventFilters] = useState({
    bank_code: '',
    provider: '',
    status: '',
    search: '',
    created_from: '',
    created_to: '',
  });

  const mailboxById = useMemo(() => {
    const entries = new Map<number, EmailMailboxOut>();
    mailboxes.forEach((item) => entries.set(item.id, item));
    return entries;
  }, [mailboxes]);

  async function loadConfigData() {
    try {
      setLoadingConfig(true);
      setError(null);
      setFeatureDisabled(false);
      const [banksResp, mailboxesResp, routesResp, runtimeResp, serviceTokenRows] = await Promise.all([
        api.get<BankOut[]>('/banks'),
        api.get<PaginatedResponse<EmailMailboxOut>>('/email-ingestion/mailboxes?page=1&page_size=1000'),
        api.get<PaginatedResponse<EmailBankRouteOut>>('/email-ingestion/routes?page=1&page_size=1000'),
        api.get<PaginatedResponse<RuntimeSetting>>('/runtime-settings?page=1&page_size=1000&search=EMAIL_'),
        api.get<ServiceApiTokenOut[]>('/email-ingestion/service-tokens'),
      ]);

      setBanks(banksResp);
      setMailboxes(mailboxesResp.items);
      setRoutes(routesResp.items);
      setServiceTokens(serviceTokenRows);

      const mailboxEditMap: Record<number, MailboxEditState> = {};
      for (const mailbox of mailboxesResp.items) {
        mailboxEditMap[mailbox.id] = {
          mailbox_email: mailbox.mailbox_email,
          display_name: mailbox.display_name || '',
          is_active: mailbox.is_active,
        };
      }
      setMailboxEdits(mailboxEditMap);

      const routeByBank = new Map<string, EmailBankRouteOut>();
      for (const route of routesResp.items) {
        routeByBank.set(route.bank_code, route);
      }
      const nextRouteForms: Record<string, RouteFormState> = {};
      for (const bank of banksResp) {
        const route = routeByBank.get(bank.code);
        nextRouteForms[bank.code] = {
          mailbox_id: route ? String(route.mailbox_id) : '',
          sender_allowlist: toCsv(route?.sender_allowlist_json),
          subject_keywords: toCsv(route?.subject_keywords_json),
          attachment_filename_regex: route?.attachment_filename_regex || '',
          gmail_label_filter_json: toJsonInput(route?.gmail_label_filter_json),
          is_active: route ? route.is_active : true,
        };
      }
      setRouteForms(nextRouteForms);

      const runtimeMap: Record<string, RuntimeSetting> = {};
      runtimeResp.items.forEach((item) => {
        runtimeMap[item.key] = item;
      });
      setRuntimeByKey(runtimeMap);

      setOauthForm((prev) => ({
        microsoft_client_id: prev.microsoft_client_id || runtimeMap.EMAIL_MS_CLIENT_ID?.value || '',
        microsoft_client_secret: '',
        gmail_client_id: prev.gmail_client_id || runtimeMap.EMAIL_GMAIL_CLIENT_ID?.value || '',
        gmail_client_secret: '',
      }));
    } catch (loadError) {
      const message = (loadError as Error).message;
      if (message.includes('HTTP 404') && message.toLowerCase().includes('email ingestion')) {
        setFeatureDisabled(true);
        setError(null);
      } else {
        setError(message);
      }
    } finally {
      setLoadingConfig(false);
    }
  }

  async function loadEvents(nextPage = eventsPage, nextPageSize = eventsPageSize) {
    try {
      setLoadingEvents(true);
      setError(null);
      const params = new URLSearchParams();
      params.set('page', String(nextPage));
      params.set('page_size', String(nextPageSize));
      if (eventFilters.bank_code.trim()) {
        params.set('bank_code', eventFilters.bank_code.trim().toUpperCase());
      }
      if (eventFilters.provider.trim()) {
        params.set('provider', eventFilters.provider.trim());
      }
      if (eventFilters.status.trim()) {
        params.set('status', eventFilters.status.trim());
      }
      if (eventFilters.search.trim()) {
        params.set('search', eventFilters.search.trim());
      }
      const createdFromIso = fromDateTimeLocalInput(eventFilters.created_from);
      if (createdFromIso) {
        params.set('created_from', createdFromIso);
      }
      const createdToIso = fromDateTimeLocalInput(eventFilters.created_to);
      if (createdToIso) {
        params.set('created_to', createdToIso);
      }

      const resp = await api.get<PaginatedResponse<EmailIngestionEventOut>>(`/email-ingestion/events?${params.toString()}`);
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
      setLoadingEvents(false);
    }
  }

  async function saveRuntimeSetting(
    key: string,
    value: string,
    isSecret: boolean,
    description: string,
  ): Promise<void> {
    if (!value.trim()) {
      setError(`Value required for ${key}.`);
      return;
    }
    await api.post<RuntimeSetting>('/runtime-settings', {
      key,
      value: value.trim(),
      bank_code: null,
      is_secret: isSecret,
      description,
    });
    setStatusMessage(`Saved ${key}`);
  }

  async function createMailbox() {
    if (!createMailboxForm.mailbox_email.trim()) {
      setError('Mailbox email is required.');
      return;
    }
    try {
      setError(null);
      await api.post<EmailMailboxOut>('/email-ingestion/mailboxes', {
        provider: createMailboxForm.provider,
        mailbox_email: createMailboxForm.mailbox_email.trim(),
        display_name: createMailboxForm.display_name.trim() || null,
        is_active: createMailboxForm.is_active,
      });
      setCreateMailboxForm({
        provider: createMailboxForm.provider,
        mailbox_email: '',
        display_name: '',
        is_active: true,
      });
      setStatusMessage('Mailbox created.');
      await loadConfigData();
    } catch (createError) {
      setError((createError as Error).message);
    }
  }

  async function saveMailbox(mailboxId: number) {
    const edit = mailboxEdits[mailboxId];
    if (!edit) {
      return;
    }
    try {
      setError(null);
      await api.patch<EmailMailboxOut>(`/email-ingestion/mailboxes/${mailboxId}`, {
        mailbox_email: edit.mailbox_email.trim(),
        display_name: edit.display_name.trim() || null,
        is_active: edit.is_active,
      });
      setStatusMessage(`Mailbox ${mailboxId} saved.`);
      await loadConfigData();
    } catch (saveError) {
      setError((saveError as Error).message);
    }
  }

  async function saveRoute(bankCode: string) {
    const form = routeForms[bankCode];
    if (!form) {
      return;
    }
    const mailboxId = Number(form.mailbox_id);
    if (!Number.isInteger(mailboxId) || mailboxId <= 0) {
      setError(`Select a mailbox for ${bankCode}.`);
      return;
    }
    let labelFilter: Record<string, unknown> | null = null;
    if (form.gmail_label_filter_json.trim()) {
      try {
        labelFilter = JSON.parse(form.gmail_label_filter_json) as Record<string, unknown>;
      } catch {
        setError(`Invalid Gmail label JSON for ${bankCode}.`);
        return;
      }
    }
    try {
      setError(null);
      await api.put<EmailBankRouteOut>(`/email-ingestion/routes/${encodeURIComponent(bankCode)}`, {
        mailbox_id: mailboxId,
        sender_allowlist_json: fromCsv(form.sender_allowlist),
        subject_keywords_json: fromCsv(form.subject_keywords),
        attachment_filename_regex: form.attachment_filename_regex.trim() || null,
        gmail_label_filter_json: labelFilter,
        is_active: form.is_active,
      });
      setStatusMessage(`Route saved for ${bankCode}.`);
      await loadConfigData();
    } catch (saveError) {
      setError((saveError as Error).message);
    }
  }

  async function saveProviderSecrets(provider: EmailProvider) {
    try {
      setError(null);
      if (provider === 'microsoft') {
        await saveRuntimeSetting('EMAIL_MS_CLIENT_ID', oauthForm.microsoft_client_id, false, 'Microsoft OAuth client id');
        await saveRuntimeSetting(
          'EMAIL_MS_CLIENT_SECRET',
          oauthForm.microsoft_client_secret,
          true,
          'Microsoft OAuth client secret',
        );
        setOauthForm((prev) => ({ ...prev, microsoft_client_secret: '' }));
      } else {
        await saveRuntimeSetting('EMAIL_GMAIL_CLIENT_ID', oauthForm.gmail_client_id, false, 'Gmail OAuth client id');
        await saveRuntimeSetting(
          'EMAIL_GMAIL_CLIENT_SECRET',
          oauthForm.gmail_client_secret,
          true,
          'Gmail OAuth client secret',
        );
        setOauthForm((prev) => ({ ...prev, gmail_client_secret: '' }));
      }
      await loadConfigData();
    } catch (saveError) {
      setError((saveError as Error).message);
    }
  }

  async function saveMailboxRefreshToken(mailbox: EmailMailboxOut) {
    const value = refreshTokensByMailbox[mailbox.id] || '';
    const key =
      mailbox.provider === 'microsoft'
        ? `EMAIL_MS_REFRESH_TOKEN_MAILBOX_${mailbox.id}`
        : `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_${mailbox.id}`;
    const description =
      mailbox.provider === 'microsoft'
        ? `Microsoft refresh token for mailbox ${mailbox.mailbox_email}`
        : `Gmail refresh token for mailbox ${mailbox.mailbox_email}`;
    try {
      setError(null);
      await saveRuntimeSetting(key, value, true, description);
      setRefreshTokensByMailbox((prev) => ({ ...prev, [mailbox.id]: '' }));
      await loadConfigData();
    } catch (saveError) {
      setError((saveError as Error).message);
    }
  }

  async function createServiceToken() {
    if (!createTokenForm.name.trim()) {
      setError('Service token name is required.');
      return;
    }
    if (createTokenForm.scopes.length === 0) {
      setError('Select at least one scope.');
      return;
    }
    try {
      setError(null);
      const created = await api.post<ServiceApiTokenCreated>('/email-ingestion/service-tokens', {
        name: createTokenForm.name.trim(),
        scopes: createTokenForm.scopes,
      });
      setCreatedServiceToken(created.token);
      setCreateTokenForm((prev) => ({ ...prev, name: '' }));
      setStatusMessage(`Created service token ${created.item.name}.`);
      await loadConfigData();
    } catch (createError) {
      setError((createError as Error).message);
    }
  }

  async function revokeServiceToken(tokenId: number) {
    try {
      setError(null);
      await api.post<ServiceApiTokenOut>(`/email-ingestion/service-tokens/${tokenId}/revoke`);
      setStatusMessage(`Revoked service token ${tokenId}.`);
      await loadConfigData();
    } catch (revokeError) {
      setError((revokeError as Error).message);
    }
  }

  useEffect(() => {
    setEventsPage(1);
  }, [activeProfileKey]);

  useEffect(() => {
    loadConfigData();
  }, [activeProfileKey]);

  useEffect(() => {
    loadEvents(eventsPage, eventsPageSize);
  }, [activeProfileKey, eventsPage, eventsPageSize]);

  const runtimeStatus = useMemo(() => {
    const lookup = (key: string) => (runtimeByKey[key]?.has_value ? 'Stored' : 'Missing');
    return {
      microsoft_client_id: lookup('EMAIL_MS_CLIENT_ID'),
      microsoft_client_secret: lookup('EMAIL_MS_CLIENT_SECRET'),
      gmail_client_id: lookup('EMAIL_GMAIL_CLIENT_ID'),
      gmail_client_secret: lookup('EMAIL_GMAIL_CLIENT_SECRET'),
    };
  }, [runtimeByKey]);

  if (featureDisabled) {
    return (
      <div className="grid">
        <Panel title="Email Ingestion">
          <p className="muted">
            Email ingestion is disabled for this environment. Enable <code>CCS_PLATFORM_EMAIL_INGESTION_ENABLED=true</code>{' '}
            and reload the page.
          </p>
        </Panel>
      </div>
    );
  }

  return (
    <div className="grid">
      <Panel title="Mailboxes">
        <p className="muted">
          Configure mailbox identities and OAuth runtime secrets used by automated email ingestion workers.
        </p>
        {error ? <p className="error" style={{ marginTop: '0.6rem' }}>{error}</p> : null}
        {statusMessage ? <p className="muted" style={{ marginTop: '0.6rem' }}>{statusMessage}</p> : null}
        {loadingConfig ? <p className="muted" style={{ marginTop: '0.6rem' }}>Loading email-ingestion config...</p> : null}

        <div className="row" style={{ marginTop: '0.75rem' }}>
          <select
            value={createMailboxForm.provider}
            onChange={(event) =>
              setCreateMailboxForm((prev) => ({ ...prev, provider: event.target.value as EmailProvider }))
            }
          >
            <option value="microsoft">Microsoft</option>
            <option value="gmail">Gmail</option>
          </select>
          <input
            value={createMailboxForm.mailbox_email}
            onChange={(event) => setCreateMailboxForm((prev) => ({ ...prev, mailbox_email: event.target.value }))}
            placeholder="mailbox email"
          />
          <input
            value={createMailboxForm.display_name}
            onChange={(event) => setCreateMailboxForm((prev) => ({ ...prev, display_name: event.target.value }))}
            placeholder="display name (optional)"
          />
          <label style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
            <input
              type="checkbox"
              checked={createMailboxForm.is_active}
              onChange={(event) => setCreateMailboxForm((prev) => ({ ...prev, is_active: event.target.checked }))}
            />
            Active
          </label>
          <button className="primary" onClick={createMailbox}>Add Mailbox</button>
          <button className="ghost" onClick={() => loadConfigData()}>Refresh</button>
        </div>

        <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Provider</th>
                <th>Mailbox</th>
                <th>Display</th>
                <th>Active</th>
                <th>Watch Expiry</th>
                <th>Last Sync</th>
                <th>Last Error</th>
                <th>Refresh Token</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {mailboxes.map((row) => {
                const edit = mailboxEdits[row.id] || {
                  mailbox_email: row.mailbox_email,
                  display_name: row.display_name || '',
                  is_active: row.is_active,
                };
                const refreshKey =
                  row.provider === 'microsoft'
                    ? `EMAIL_MS_REFRESH_TOKEN_MAILBOX_${row.id}`
                    : `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_${row.id}`;
                const refreshStored = runtimeByKey[refreshKey]?.has_value ? 'Stored' : 'Missing';
                return (
                  <tr key={row.id}>
                    <td>{row.id}</td>
                    <td>{providerLabel(row.provider)}</td>
                    <td>
                      <input
                        value={edit.mailbox_email}
                        onChange={(event) =>
                          setMailboxEdits((prev) => ({
                            ...prev,
                            [row.id]: { ...edit, mailbox_email: event.target.value },
                          }))
                        }
                        style={{ width: '100%' }}
                      />
                    </td>
                    <td>
                      <input
                        value={edit.display_name}
                        onChange={(event) =>
                          setMailboxEdits((prev) => ({
                            ...prev,
                            [row.id]: { ...edit, display_name: event.target.value },
                          }))
                        }
                        style={{ width: '100%' }}
                      />
                    </td>
                    <td>
                      <label style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem' }}>
                        <input
                          type="checkbox"
                          checked={edit.is_active}
                          onChange={(event) =>
                            setMailboxEdits((prev) => ({
                              ...prev,
                              [row.id]: { ...edit, is_active: event.target.checked },
                            }))
                          }
                        />
                        {edit.is_active ? 'yes' : 'no'}
                      </label>
                    </td>
                    <td>{formatLocalDateTime(row.watch_expiration_at)}</td>
                    <td>{formatLocalDateTime(row.last_sync_at)}</td>
                    <td>{row.last_error_message || '-'}</td>
                    <td style={{ minWidth: '280px' }}>
                      <div className="row">
                        <input
                          type="password"
                          value={refreshTokensByMailbox[row.id] || ''}
                          onChange={(event) =>
                            setRefreshTokensByMailbox((prev) => ({ ...prev, [row.id]: event.target.value }))
                          }
                          placeholder={`Refresh token (${refreshStored})`}
                          style={{ width: '100%' }}
                        />
                        <button className="ghost" onClick={() => saveMailboxRefreshToken(row)}>Save Token</button>
                      </div>
                    </td>
                    <td>
                      <button className="primary" onClick={() => saveMailbox(row.id)}>Save</button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        <div className="grid" style={{ marginTop: '0.9rem' }}>
          <div className="panel" style={{ padding: '0.75rem' }}>
            <h4>Microsoft OAuth</h4>
            <p className="muted" style={{ marginTop: '0.35rem' }}>
              Client ID: {runtimeStatus.microsoft_client_id} | Client Secret: {runtimeStatus.microsoft_client_secret}
            </p>
            <div className="row" style={{ marginTop: '0.5rem' }}>
              <input
                value={oauthForm.microsoft_client_id}
                onChange={(event) => setOauthForm((prev) => ({ ...prev, microsoft_client_id: event.target.value }))}
                placeholder="EMAIL_MS_CLIENT_ID"
              />
              <input
                type="password"
                value={oauthForm.microsoft_client_secret}
                onChange={(event) =>
                  setOauthForm((prev) => ({ ...prev, microsoft_client_secret: event.target.value }))
                }
                placeholder="EMAIL_MS_CLIENT_SECRET"
              />
              <button className="primary" onClick={() => saveProviderSecrets('microsoft')}>Save Microsoft Keys</button>
            </div>
          </div>

          <div className="panel" style={{ padding: '0.75rem' }}>
            <h4>Gmail OAuth</h4>
            <p className="muted" style={{ marginTop: '0.35rem' }}>
              Client ID: {runtimeStatus.gmail_client_id} | Client Secret: {runtimeStatus.gmail_client_secret}
            </p>
            <div className="row" style={{ marginTop: '0.5rem' }}>
              <input
                value={oauthForm.gmail_client_id}
                onChange={(event) => setOauthForm((prev) => ({ ...prev, gmail_client_id: event.target.value }))}
                placeholder="EMAIL_GMAIL_CLIENT_ID"
              />
              <input
                type="password"
                value={oauthForm.gmail_client_secret}
                onChange={(event) => setOauthForm((prev) => ({ ...prev, gmail_client_secret: event.target.value }))}
                placeholder="EMAIL_GMAIL_CLIENT_SECRET"
              />
              <button className="primary" onClick={() => saveProviderSecrets('gmail')}>Save Gmail Keys</button>
            </div>
          </div>
        </div>
      </Panel>

      <Panel title="Bank Routing Matrix">
        <p className="muted">
          One route is stored per enabled bank for this profile. Use filters to target sender, subject, and attachment names.
        </p>
        <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
          <table>
            <thead>
              <tr>
                <th>Bank</th>
                <th>Mailbox</th>
                <th>Sender Allowlist</th>
                <th>Subject Keywords</th>
                <th>Filename Regex</th>
                <th>Gmail Label Filter (JSON)</th>
                <th>Active</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {banks.map((bank) => {
                const form = routeForms[bank.code] || {
                  mailbox_id: '',
                  sender_allowlist: '',
                  subject_keywords: '',
                  attachment_filename_regex: '',
                  gmail_label_filter_json: '',
                  is_active: true,
                };
                const selectedMailbox = mailboxById.get(Number(form.mailbox_id));
                return (
                  <tr key={bank.code}>
                    <td>{bank.code}</td>
                    <td>
                      <select
                        value={form.mailbox_id}
                        onChange={(event) =>
                          setRouteForms((prev) => ({
                            ...prev,
                            [bank.code]: { ...form, mailbox_id: event.target.value },
                          }))
                        }
                        style={{ minWidth: '220px' }}
                      >
                        <option value="">Select mailbox</option>
                        {mailboxes.map((mailbox) => (
                          <option key={mailbox.id} value={String(mailbox.id)}>
                            {providerLabel(mailbox.provider)} | {mailbox.mailbox_email}
                          </option>
                        ))}
                      </select>
                      {selectedMailbox ? (
                        <p className="muted" style={{ marginTop: '0.3rem' }}>
                          {providerLabel(selectedMailbox.provider)}
                        </p>
                      ) : null}
                    </td>
                    <td>
                      <input
                        value={form.sender_allowlist}
                        onChange={(event) =>
                          setRouteForms((prev) => ({
                            ...prev,
                            [bank.code]: { ...form, sender_allowlist: event.target.value },
                          }))
                        }
                        placeholder="comma separated emails"
                        style={{ width: '100%' }}
                      />
                    </td>
                    <td>
                      <input
                        value={form.subject_keywords}
                        onChange={(event) =>
                          setRouteForms((prev) => ({
                            ...prev,
                            [bank.code]: { ...form, subject_keywords: event.target.value },
                          }))
                        }
                        placeholder="comma separated keywords"
                        style={{ width: '100%' }}
                      />
                    </td>
                    <td>
                      <input
                        value={form.attachment_filename_regex}
                        onChange={(event) =>
                          setRouteForms((prev) => ({
                            ...prev,
                            [bank.code]: { ...form, attachment_filename_regex: event.target.value },
                          }))
                        }
                        placeholder=".*statement.*\\.pdf"
                        style={{ width: '100%' }}
                      />
                    </td>
                    <td>
                      <input
                        value={form.gmail_label_filter_json}
                        onChange={(event) =>
                          setRouteForms((prev) => ({
                            ...prev,
                            [bank.code]: { ...form, gmail_label_filter_json: event.target.value },
                          }))
                        }
                        placeholder='{"label_ids":["Label_1"]}'
                        style={{ width: '100%' }}
                      />
                    </td>
                    <td>
                      <label style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem' }}>
                        <input
                          type="checkbox"
                          checked={form.is_active}
                          onChange={(event) =>
                            setRouteForms((prev) => ({
                              ...prev,
                              [bank.code]: { ...form, is_active: event.target.checked },
                            }))
                          }
                        />
                        {form.is_active ? 'yes' : 'no'}
                      </label>
                    </td>
                    <td>
                      <button className="primary" onClick={() => saveRoute(bank.code)}>Save</button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </Panel>

      <Panel title="Ingestion Activity">
        <div className="row">
          <select
            value={eventFilters.bank_code}
            onChange={(event) => {
              setEventFilters((prev) => ({ ...prev, bank_code: event.target.value }));
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
            value={eventFilters.provider}
            onChange={(event) => {
              setEventFilters((prev) => ({ ...prev, provider: event.target.value }));
              setEventsPage(1);
            }}
          >
            <option value="">All providers</option>
            <option value="microsoft">Microsoft</option>
            <option value="gmail">Gmail</option>
          </select>
          <select
            value={eventFilters.status}
            onChange={(event) => {
              setEventFilters((prev) => ({ ...prev, status: event.target.value }));
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
            value={eventFilters.search}
            onChange={(event) => {
              setEventFilters((prev) => ({ ...prev, search: event.target.value }));
              setEventsPage(1);
            }}
            placeholder="Search attachment/message id"
          />
          <label style={{ display: 'inline-grid', gap: '0.2rem' }}>
            <span className="muted">From</span>
            <input
              type="datetime-local"
              value={eventFilters.created_from}
              onChange={(event) => {
                setEventFilters((prev) => ({ ...prev, created_from: event.target.value }));
                setEventsPage(1);
              }}
            />
          </label>
          <label style={{ display: 'inline-grid', gap: '0.2rem' }}>
            <span className="muted">To</span>
            <input
              type="datetime-local"
              value={eventFilters.created_to}
              onChange={(event) => {
                setEventFilters((prev) => ({ ...prev, created_to: event.target.value }));
                setEventsPage(1);
              }}
            />
          </label>
          <button className="ghost" onClick={() => loadEvents(1, eventsPageSize)}>Apply Filters</button>
          <button className="ghost" onClick={() => loadEvents(eventsPage, eventsPageSize)}>Refresh</button>
        </div>

        {loadingEvents ? <p className="muted" style={{ marginTop: '0.55rem' }}>Loading ingestion events...</p> : null}

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
                    <div className="muted" title={item.provider_attachment_id}>{item.provider_attachment_id.slice(0, 18)}...</div>
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
          disabled={loadingEvents}
          onPageChange={setEventsPage}
          onPageSizeChange={(nextPageSize) => {
            setEventsPageSize(nextPageSize);
            setEventsPage(1);
          }}
        />
      </Panel>

      <Panel title="Service Tokens">
        <p className="muted">Create machine tokens for GitHub Actions and Cloud Run workers. Token value is shown once.</p>
        <div className="row" style={{ marginTop: '0.75rem' }}>
          <input
            value={createTokenForm.name}
            onChange={(event) => setCreateTokenForm((prev) => ({ ...prev, name: event.target.value }))}
            placeholder="token name"
          />
          <div className="row">
            {SERVICE_SCOPE_OPTIONS.map((scope) => {
              const checked = createTokenForm.scopes.includes(scope);
              return (
                <label key={scope} style={{ display: 'inline-flex', alignItems: 'center', gap: '0.35rem' }}>
                  <input
                    type="checkbox"
                    checked={checked}
                    onChange={(event) =>
                      setCreateTokenForm((prev) => ({
                        ...prev,
                        scopes: event.target.checked
                          ? [...new Set([...prev.scopes, scope])]
                          : prev.scopes.filter((item) => item !== scope),
                      }))
                    }
                  />
                  <code>{scope}</code>
                </label>
              );
            })}
          </div>
          <button className="primary" onClick={createServiceToken}>Create Service Token</button>
        </div>

        {createdServiceToken ? (
          <div style={{ marginTop: '0.75rem' }}>
            <p className="muted">Copy this token now. It will not be shown again.</p>
            <textarea
              value={createdServiceToken}
              readOnly
              rows={2}
              style={{ width: '100%', marginTop: '0.35rem' }}
            />
          </div>
        ) : null}

        <div className="table-wrap" style={{ marginTop: '0.75rem' }}>
          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Name</th>
                <th>Prefix</th>
                <th>Scopes</th>
                <th>Status</th>
                <th>Last Used</th>
                <th>Created</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {serviceTokens.map((row) => (
                <tr key={row.id}>
                  <td>{row.id}</td>
                  <td>{row.name}</td>
                  <td><code>{row.token_prefix}</code></td>
                  <td><code>{(row.scopes_json || []).join(', ')}</code></td>
                  <td>{row.is_active ? 'active' : 'revoked'}</td>
                  <td>{formatLocalDateTime(row.last_used_at)}</td>
                  <td>{formatLocalDateTime(row.created_at)}</td>
                  <td>
                    {row.is_active ? (
                      <button className="ghost" onClick={() => revokeServiceToken(row.id)}>Revoke</button>
                    ) : (
                      '-'
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Panel>
    </div>
  );
}
