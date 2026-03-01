import { useEffect, useState } from 'react';

import { api } from '../api';
import { Panel } from '../components/Panel';
import { BankRoutingMatrix } from '../components/email/BankRoutingMatrix';
import { MailboxesPanel } from '../components/email/MailboxesPanel';
import { OAuthTokenPanel } from '../components/email/OAuthTokenPanel';
import { ServiceTokensPanel } from '../components/email/ServiceTokensPanel';
import {
  BankOut,
  CreateMailboxForm,
  EmailBankRouteOut,
  EmailMailboxOut,
  OAuthConfigOut,
  OAuthProviderState,
  PaginatedResponse,
  RouteFormState,
  RuntimeSetting,
  SERVICE_SCOPE_OPTIONS,
  ServiceApiTokenCreated,
  ServiceApiTokenOut,
  fromCsv,
  toCsv,
  toJsonInput,
} from '../components/email/types';
import { extractErrorMessage } from '../lib/errors';
import { useActiveProfileKey } from '../profileStore';

export function EmailIngestionPage() {
  const activeProfileKey = useActiveProfileKey();
  const [featureDisabled, setFeatureDisabled] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [loadingConfig, setLoadingConfig] = useState(false);

  const [banks, setBanks] = useState<BankOut[]>([]);
  const [mailboxes, setMailboxes] = useState<EmailMailboxOut[]>([]);
  const [mailboxEdits, setMailboxEdits] = useState<Record<number, { mailbox_email: string; display_name: string; is_active: boolean }>>({});
  const [routeForms, setRouteForms] = useState<Record<string, RouteFormState>>({});
  const [runtimeByKey, setRuntimeByKey] = useState<Record<string, RuntimeSetting>>({});
  const [serviceTokens, setServiceTokens] = useState<ServiceApiTokenOut[]>([]);
  const [createdServiceToken, setCreatedServiceToken] = useState<string | null>(null);
  const [createMailboxForm, setCreateMailboxForm] = useState<CreateMailboxForm>({
    provider: 'microsoft',
    mailbox_email: '',
    display_name: '',
    is_active: true,
  });
  const [refreshTokensByMailbox, setRefreshTokensByMailbox] = useState<Record<number, string>>({});
  const [oauthConfigs, setOAuthConfigs] = useState<OAuthConfigOut[]>([]);
  const [oauthState, setOAuthState] = useState<Record<'microsoft' | 'gmail', OAuthProviderState>>({
    microsoft: { code: '', refreshToken: '', selectedMailboxId: '', loading: false, error: null, saved: false },
    gmail: { code: '', refreshToken: '', selectedMailboxId: '', loading: false, error: null, saved: false },
  });
  const [createTokenForm, setCreateTokenForm] = useState({
    name: '',
    scopes: [...SERVICE_SCOPE_OPTIONS] as string[],
  });

  async function loadConfigData() {
    try {
      setLoadingConfig(true);
      setError(null);
      setFeatureDisabled(false);
      const [banksResp, mailboxesResp, routesResp, runtimeResp, serviceTokenRows, oauthConfigResp] = await Promise.all([
        api.get<BankOut[]>('/banks'),
        api.get<PaginatedResponse<EmailMailboxOut>>('/email-ingestion/mailboxes?page=1&page_size=1000'),
        api.get<PaginatedResponse<EmailBankRouteOut>>('/email-ingestion/routes?page=1&page_size=1000'),
        api.get<PaginatedResponse<RuntimeSetting>>('/runtime-settings?page=1&page_size=1000&search=EMAIL_'),
        api.get<ServiceApiTokenOut[]>('/email-ingestion/service-tokens'),
        api.get<OAuthConfigOut[]>('/email-ingestion/oauth/config'),
      ]);

      setBanks(banksResp);
      setMailboxes(mailboxesResp.items);
      setServiceTokens(serviceTokenRows);
      setOAuthConfigs(oauthConfigResp);

      const mailboxEditMap: Record<number, { mailbox_email: string; display_name: string; is_active: boolean }> = {};
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
      runtimeResp.items.forEach((item) => { runtimeMap[item.key] = item; });
      setRuntimeByKey(runtimeMap);
    } catch (loadError) {
      const message = extractErrorMessage(loadError);
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

  async function saveRuntimeSetting(key: string, value: string, isSecret: boolean, description: string): Promise<void> {
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
      setCreateMailboxForm({ provider: createMailboxForm.provider, mailbox_email: '', display_name: '', is_active: true });
      setStatusMessage('Mailbox created.');
      await loadConfigData();
    } catch (err) {
      setError(extractErrorMessage(err));
    }
  }

  async function saveMailbox(mailboxId: number) {
    const edit = mailboxEdits[mailboxId];
    if (!edit) return;
    try {
      setError(null);
      await api.patch<EmailMailboxOut>(`/email-ingestion/mailboxes/${mailboxId}`, {
        mailbox_email: edit.mailbox_email.trim(),
        display_name: edit.display_name.trim() || null,
        is_active: edit.is_active,
      });
      setStatusMessage(`Mailbox ${mailboxId} saved.`);
      await loadConfigData();
    } catch (err) {
      setError(extractErrorMessage(err));
    }
  }

  async function saveRoute(bankCode: string) {
    const form = routeForms[bankCode];
    if (!form) return;
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
    } catch (err) {
      setError(extractErrorMessage(err));
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
    } catch (err) {
      setError(extractErrorMessage(err));
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
    } catch (err) {
      setError(extractErrorMessage(err));
    }
  }

  async function revokeServiceToken(tokenId: number) {
    try {
      setError(null);
      await api.post<ServiceApiTokenOut>(`/email-ingestion/service-tokens/${tokenId}/revoke`);
      setStatusMessage(`Revoked service token ${tokenId}.`);
      await loadConfigData();
    } catch (err) {
      setError(extractErrorMessage(err));
    }
  }

  useEffect(() => {
    loadConfigData();
  }, [activeProfileKey]);

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
      <MailboxesPanel
        error={error}
        statusMessage={statusMessage}
        loadingConfig={loadingConfig}
        mailboxes={mailboxes}
        mailboxEdits={mailboxEdits}
        setMailboxEdits={setMailboxEdits}
        runtimeByKey={runtimeByKey}
        refreshTokensByMailbox={refreshTokensByMailbox}
        setRefreshTokensByMailbox={setRefreshTokensByMailbox}
        createMailboxForm={createMailboxForm}
        setCreateMailboxForm={setCreateMailboxForm}
        onCreateMailbox={createMailbox}
        onSaveMailbox={saveMailbox}
        onSaveRefreshToken={saveMailboxRefreshToken}
        onRefresh={loadConfigData}
      />
      <OAuthTokenPanel
        oauthConfigs={oauthConfigs}
        oauthState={oauthState}
        setOAuthState={setOAuthState}
        mailboxes={mailboxes}
        onAfterSave={loadConfigData}
      />
      <BankRoutingMatrix
        banks={banks}
        mailboxes={mailboxes}
        routeForms={routeForms}
        setRouteForms={setRouteForms}
        onSaveRoute={saveRoute}
      />
      <ServiceTokensPanel
        serviceTokens={serviceTokens}
        createTokenForm={createTokenForm}
        setCreateTokenForm={setCreateTokenForm}
        createdServiceToken={createdServiceToken}
        onCreateToken={createServiceToken}
        onRevokeToken={revokeServiceToken}
      />
    </div>
  );
}
