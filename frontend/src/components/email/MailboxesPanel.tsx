import { Panel } from '../Panel';
import { formatLocalDateTime } from '../../utils/datetime';
import {
  CreateMailboxForm,
  EmailMailboxOut,
  EmailProvider,
  MailboxEditState,
  RuntimeSetting,
  providerLabel,
} from './types';

type MailboxesPanelProps = {
  error: string | null;
  statusMessage: string | null;
  loadingConfig: boolean;
  mailboxes: EmailMailboxOut[];
  mailboxEdits: Record<number, MailboxEditState>;
  setMailboxEdits: React.Dispatch<React.SetStateAction<Record<number, MailboxEditState>>>;
  runtimeByKey: Record<string, RuntimeSetting>;
  refreshTokensByMailbox: Record<number, string>;
  setRefreshTokensByMailbox: React.Dispatch<React.SetStateAction<Record<number, string>>>;
  createMailboxForm: CreateMailboxForm;
  setCreateMailboxForm: React.Dispatch<React.SetStateAction<CreateMailboxForm>>;
  onCreateMailbox: () => void;
  onSaveMailbox: (mailboxId: number) => void;
  onSaveRefreshToken: (mailbox: EmailMailboxOut) => void;
  onRefresh: () => void;
};

export function MailboxesPanel({
  error,
  statusMessage,
  loadingConfig,
  mailboxes,
  mailboxEdits,
  setMailboxEdits,
  runtimeByKey,
  refreshTokensByMailbox,
  setRefreshTokensByMailbox,
  createMailboxForm,
  setCreateMailboxForm,
  onCreateMailbox,
  onSaveMailbox,
  onSaveRefreshToken,
  onRefresh,
}: MailboxesPanelProps) {
  return (
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
          onChange={(e) =>
            setCreateMailboxForm((prev) => ({ ...prev, provider: e.target.value as EmailProvider }))
          }
        >
          <option value="microsoft">Microsoft</option>
          <option value="gmail">Gmail</option>
        </select>
        <input
          value={createMailboxForm.mailbox_email}
          onChange={(e) => setCreateMailboxForm((prev) => ({ ...prev, mailbox_email: e.target.value }))}
          placeholder="mailbox email"
        />
        <input
          value={createMailboxForm.display_name}
          onChange={(e) => setCreateMailboxForm((prev) => ({ ...prev, display_name: e.target.value }))}
          placeholder="display name (optional)"
        />
        <label style={{ display: 'inline-flex', alignItems: 'center', gap: '0.4rem' }}>
          <input
            type="checkbox"
            checked={createMailboxForm.is_active}
            onChange={(e) => setCreateMailboxForm((prev) => ({ ...prev, is_active: e.target.checked }))}
          />
          Active
        </label>
        <button className="primary" onClick={onCreateMailbox}>Add Mailbox</button>
        <button className="ghost" onClick={onRefresh}>Refresh</button>
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
                      onChange={(e) =>
                        setMailboxEdits((prev) => ({
                          ...prev,
                          [row.id]: { ...edit, mailbox_email: e.target.value },
                        }))
                      }
                      style={{ width: '100%' }}
                    />
                  </td>
                  <td>
                    <input
                      value={edit.display_name}
                      onChange={(e) =>
                        setMailboxEdits((prev) => ({
                          ...prev,
                          [row.id]: { ...edit, display_name: e.target.value },
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
                        onChange={(e) =>
                          setMailboxEdits((prev) => ({
                            ...prev,
                            [row.id]: { ...edit, is_active: e.target.checked },
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
                        onChange={(e) =>
                          setRefreshTokensByMailbox((prev) => ({ ...prev, [row.id]: e.target.value }))
                        }
                        placeholder={`Refresh token (${refreshStored})`}
                        style={{ width: '100%' }}
                      />
                      <button className="ghost" onClick={() => onSaveRefreshToken(row)}>Save Token</button>
                    </div>
                  </td>
                  <td>
                    <button className="primary" onClick={() => onSaveMailbox(row.id)}>Save</button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </Panel>
  );
}
