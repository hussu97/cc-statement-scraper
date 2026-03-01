import { useState } from 'react';

import { formatLocalDateTime } from '../../utils/datetime';
import { ConfirmDialog } from '../ConfirmDialog';
import { Panel } from '../Panel';
import { SERVICE_SCOPE_OPTIONS, ServiceApiTokenOut } from './types';

type CreateTokenForm = {
  name: string;
  scopes: string[];
};

type ServiceTokensPanelProps = {
  serviceTokens: ServiceApiTokenOut[];
  createTokenForm: CreateTokenForm;
  setCreateTokenForm: React.Dispatch<React.SetStateAction<CreateTokenForm>>;
  createdServiceToken: string | null;
  onCreateToken: () => void;
  onRevokeToken: (tokenId: number) => void;
};

export function ServiceTokensPanel({
  serviceTokens,
  createTokenForm,
  setCreateTokenForm,
  createdServiceToken,
  onCreateToken,
  onRevokeToken,
}: ServiceTokensPanelProps) {
  const [confirmRevoke, setConfirmRevoke] = useState<{ id: number; name: string } | null>(null);

  return (
    <Panel title="Service Tokens">
      <p className="muted">Create machine tokens for GitHub Actions and Cloud Run workers. Token value is shown once.</p>

      <div className="row" style={{ marginTop: '0.75rem' }}>
        <input
          value={createTokenForm.name}
          onChange={(e) => setCreateTokenForm((prev) => ({ ...prev, name: e.target.value }))}
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
                  onChange={(e) =>
                    setCreateTokenForm((prev) => ({
                      ...prev,
                      scopes: e.target.checked
                        ? [...new Set([...prev.scopes, scope])]
                        : prev.scopes.filter((s) => s !== scope),
                    }))
                  }
                />
                <code>{scope}</code>
              </label>
            );
          })}
        </div>
        <button className="primary" onClick={onCreateToken}>Create Service Token</button>
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
                    <button className="ghost" onClick={() => setConfirmRevoke({ id: row.id, name: row.name })}>
                      Revoke
                    </button>
                  ) : (
                    '-'
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <ConfirmDialog
        isOpen={confirmRevoke !== null}
        title="Revoke Service Token"
        message={
          confirmRevoke
            ? `Are you sure you want to revoke "${confirmRevoke.name}"? Any service using this token will lose access immediately.`
            : ''
        }
        confirmLabel="Revoke"
        onConfirm={() => {
          if (confirmRevoke) onRevokeToken(confirmRevoke.id);
          setConfirmRevoke(null);
        }}
        onCancel={() => setConfirmRevoke(null)}
      />
    </Panel>
  );
}
