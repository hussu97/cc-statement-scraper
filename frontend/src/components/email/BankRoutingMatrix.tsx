import { useMemo } from 'react';

import { Panel } from '../Panel';
import { BankOut, EmailMailboxOut, RouteFormState, providerLabel } from './types';

type BankRoutingMatrixProps = {
  banks: BankOut[];
  mailboxes: EmailMailboxOut[];
  routeForms: Record<string, RouteFormState>;
  setRouteForms: React.Dispatch<React.SetStateAction<Record<string, RouteFormState>>>;
  onSaveRoute: (bankCode: string) => void;
};

export function BankRoutingMatrix({
  banks,
  mailboxes,
  routeForms,
  setRouteForms,
  onSaveRoute,
}: BankRoutingMatrixProps) {
  const mailboxById = useMemo(() => {
    const map = new Map<number, EmailMailboxOut>();
    mailboxes.forEach((m) => map.set(m.id, m));
    return map;
  }, [mailboxes]);

  return (
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
                      onChange={(e) =>
                        setRouteForms((prev) => ({
                          ...prev,
                          [bank.code]: { ...form, mailbox_id: e.target.value },
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
                      onChange={(e) =>
                        setRouteForms((prev) => ({
                          ...prev,
                          [bank.code]: { ...form, sender_allowlist: e.target.value },
                        }))
                      }
                      placeholder="comma separated emails"
                      style={{ width: '100%' }}
                    />
                  </td>
                  <td>
                    <input
                      value={form.subject_keywords}
                      onChange={(e) =>
                        setRouteForms((prev) => ({
                          ...prev,
                          [bank.code]: { ...form, subject_keywords: e.target.value },
                        }))
                      }
                      placeholder="comma separated keywords"
                      style={{ width: '100%' }}
                    />
                  </td>
                  <td>
                    <input
                      value={form.attachment_filename_regex}
                      onChange={(e) =>
                        setRouteForms((prev) => ({
                          ...prev,
                          [bank.code]: { ...form, attachment_filename_regex: e.target.value },
                        }))
                      }
                      placeholder=".*statement.*\.pdf"
                      style={{ width: '100%' }}
                    />
                  </td>
                  <td>
                    <input
                      value={form.gmail_label_filter_json}
                      onChange={(e) =>
                        setRouteForms((prev) => ({
                          ...prev,
                          [bank.code]: { ...form, gmail_label_filter_json: e.target.value },
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
                        onChange={(e) =>
                          setRouteForms((prev) => ({
                            ...prev,
                            [bank.code]: { ...form, is_active: e.target.checked },
                          }))
                        }
                      />
                      {form.is_active ? 'yes' : 'no'}
                    </label>
                  </td>
                  <td>
                    <button className="primary" onClick={() => onSaveRoute(bank.code)}>Save</button>
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
