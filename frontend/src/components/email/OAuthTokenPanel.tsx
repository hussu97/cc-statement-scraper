import { api } from '../../api';
import { Panel } from '../Panel';
import {
  EmailMailboxOut,
  EmailProvider,
  OAuthConfigOut,
  OAuthProviderState,
  providerLabel,
} from './types';

type OAuthTokenPanelProps = {
  oauthConfigs: OAuthConfigOut[];
  oauthState: Record<EmailProvider, OAuthProviderState>;
  setOAuthState: React.Dispatch<React.SetStateAction<Record<EmailProvider, OAuthProviderState>>>;
  mailboxes: EmailMailboxOut[];
  onAfterSave: () => void;
};

export function OAuthTokenPanel({
  oauthConfigs,
  oauthState,
  setOAuthState,
  mailboxes,
  onAfterSave,
}: OAuthTokenPanelProps) {
  return (
    <Panel title="OAuth Token Setup">
      <p className="muted">
        Click <strong>Authorize</strong> for a provider, sign in, then paste the resulting code (or the full redirect
        URL) to exchange it for a refresh token. Save the token directly to a mailbox.
      </p>
      <div style={{ display: 'flex', gap: '1.5rem', flexWrap: 'wrap', marginTop: '0.75rem' }}>
        {(['microsoft', 'gmail'] as EmailProvider[]).map((provider) => {
          const config = oauthConfigs.find((c) => c.provider === provider);
          const state = oauthState[provider];

          function setProviderState(patch: Partial<OAuthProviderState>) {
            setOAuthState((prev) => ({
              ...prev,
              [provider]: { ...prev[provider], ...patch },
            }));
          }

          function extractCode(raw: string): string {
            const match = raw.match(/[?&]code=([^&]+)/);
            return match ? decodeURIComponent(match[1]) : raw;
          }

          async function exchangeCode() {
            const code = extractCode(state.code.trim());
            if (!code) return;
            setProviderState({ loading: true, error: null, refreshToken: '', saved: false });
            try {
              const result = await api.post<{ provider: EmailProvider; refresh_token: string }>(
                '/email-ingestion/oauth/exchange-code',
                { provider, code },
              );
              setProviderState({ loading: false, refreshToken: result.refresh_token });
            } catch (err) {
              setProviderState({ loading: false, error: (err as Error).message });
            }
          }

          async function saveToMailbox() {
            const mailboxId = Number(state.selectedMailboxId);
            if (!mailboxId || !state.refreshToken) return;
            const key =
              provider === 'microsoft'
                ? `EMAIL_MS_REFRESH_TOKEN_MAILBOX_${mailboxId}`
                : `EMAIL_GMAIL_REFRESH_TOKEN_MAILBOX_${mailboxId}`;
            const mailbox = mailboxes.find((m) => m.id === mailboxId);
            const description =
              provider === 'microsoft'
                ? `Microsoft refresh token for mailbox ${mailbox?.mailbox_email ?? mailboxId}`
                : `Gmail refresh token for mailbox ${mailbox?.mailbox_email ?? mailboxId}`;
            setProviderState({ loading: true, error: null, saved: false });
            try {
              await api.post('/runtime-settings', {
                key,
                value: state.refreshToken,
                bank_code: null,
                is_secret: true,
                description,
              });
              setProviderState({ loading: false, saved: true });
              onAfterSave();
            } catch (err) {
              setProviderState({ loading: false, error: (err as Error).message });
            }
          }

          const providerMailboxes = mailboxes.filter((m) => m.provider === provider);
          const isConfigured = config?.configured ?? false;
          const authUrl = config?.auth_url ?? null;
          const label = providerLabel(provider);

          return (
            <div
              key={provider}
              style={{
                flex: '1 1 340px',
                border: '1px solid var(--border)',
                borderRadius: '6px',
                padding: '1rem',
                display: 'flex',
                flexDirection: 'column',
                gap: '0.6rem',
              }}
            >
              <strong>{label}</strong>

              {isConfigured && authUrl ? (
                <a href={authUrl} target="_blank" rel="noreferrer" className="button ghost" style={{ alignSelf: 'flex-start' }}>
                  Authorize {label} ↗
                </a>
              ) : (
                <span
                  className="muted"
                  title={`Configure CCS_PLATFORM_EMAIL_${provider === 'microsoft' ? 'MS' : 'GMAIL'}_CLIENT_ID and _CLIENT_SECRET in .env first`}
                  style={{ cursor: 'not-allowed', opacity: 0.5 }}
                >
                  Authorize {label} ↗ (not configured)
                </span>
              )}

              <div>
                <label className="muted" style={{ fontSize: '0.8rem' }}>Auth code from redirect URL</label>
                <div className="row" style={{ marginTop: '0.25rem' }}>
                  <input
                    value={state.code}
                    onChange={(e) => setProviderState({ code: e.target.value, refreshToken: '', saved: false })}
                    placeholder="Paste code or full redirect URL"
                    style={{ flex: 1 }}
                  />
                  <button className="primary" onClick={exchangeCode} disabled={state.loading || !state.code.trim()}>
                    {state.loading ? '…' : 'Get Refresh Token'}
                  </button>
                </div>
              </div>

              {state.error ? <p className="error" style={{ margin: 0, fontSize: '0.85rem' }}>{state.error}</p> : null}

              {state.refreshToken ? (
                <div>
                  <label className="muted" style={{ fontSize: '0.8rem' }}>Refresh token</label>
                  <div className="row" style={{ marginTop: '0.25rem' }}>
                    <input
                      type="password"
                      value={state.refreshToken}
                      readOnly
                      style={{ flex: 1, fontFamily: 'monospace', fontSize: '0.8rem' }}
                    />
                    <button
                      className="ghost"
                      title="Copy"
                      onClick={() => navigator.clipboard.writeText(state.refreshToken)}
                    >
                      📋
                    </button>
                  </div>
                </div>
              ) : null}

              {state.refreshToken ? (
                <div>
                  <label className="muted" style={{ fontSize: '0.8rem' }}>Save to mailbox</label>
                  <div className="row" style={{ marginTop: '0.25rem' }}>
                    <select
                      value={state.selectedMailboxId}
                      onChange={(e) => setProviderState({ selectedMailboxId: e.target.value, saved: false })}
                      style={{ flex: 1 }}
                    >
                      <option value="">Select mailbox</option>
                      {providerMailboxes.map((m) => (
                        <option key={m.id} value={String(m.id)}>
                          {m.mailbox_email}
                        </option>
                      ))}
                    </select>
                    <button
                      className="primary"
                      onClick={saveToMailbox}
                      disabled={state.loading || !state.selectedMailboxId}
                    >
                      {state.loading ? '…' : state.saved ? '✓ Saved' : 'Save to Mailbox'}
                    </button>
                  </div>
                </div>
              ) : null}
            </div>
          );
        })}
      </div>
    </Panel>
  );
}
