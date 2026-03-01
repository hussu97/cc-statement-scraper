export type EmailProvider = 'microsoft' | 'gmail';

export type PaginatedResponse<T> = {
  items: T[];
  total: number;
  page: number;
  page_size: number;
};

export type RuntimeSetting = {
  key: string;
  value: string;
  has_value: boolean;
  is_secret: boolean;
};

export type EmailMailboxOut = {
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

export type EmailBankRouteOut = {
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

export type ServiceApiTokenOut = {
  id: number;
  name: string;
  token_prefix: string;
  scopes_json: string[] | null;
  is_active: boolean;
  last_used_at: string | null;
  created_at: string;
  revoked_at: string | null;
};

export type ServiceApiTokenCreated = {
  token: string;
  item: ServiceApiTokenOut;
};

export type OAuthConfigOut = {
  provider: EmailProvider;
  auth_url: string | null;
  configured: boolean;
};

export type OAuthProviderState = {
  code: string;
  refreshToken: string;
  selectedMailboxId: string;
  loading: boolean;
  error: string | null;
  saved: boolean;
};

export type BankOut = {
  code: string;
  name: string;
};

export type MailboxEditState = {
  mailbox_email: string;
  display_name: string;
  is_active: boolean;
};

export type RouteFormState = {
  mailbox_id: string;
  sender_allowlist: string;
  subject_keywords: string;
  attachment_filename_regex: string;
  gmail_label_filter_json: string;
  is_active: boolean;
};

export type CreateMailboxForm = {
  provider: EmailProvider;
  mailbox_email: string;
  display_name: string;
  is_active: boolean;
};

export const SERVICE_SCOPE_OPTIONS = [
  'email_ingestion:read',
  'email_ingestion:write',
  'email_ingestion:upload',
] as const;

export function providerLabel(provider: EmailProvider): string {
  return provider === 'microsoft' ? 'Microsoft' : 'Gmail';
}

export function toCsv(values: string[] | null | undefined): string {
  if (!values || values.length === 0) return '';
  return values.join(', ');
}

export function fromCsv(value: string): string[] | null {
  const tokens = value
    .split(',')
    .map((token) => token.trim())
    .filter(Boolean);
  return tokens.length > 0 ? tokens : null;
}

export function toJsonInput(value: Record<string, unknown> | null | undefined): string {
  if (!value) return '';
  return JSON.stringify(value);
}
