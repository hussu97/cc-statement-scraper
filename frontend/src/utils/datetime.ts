const ISO_TZ_SUFFIX = /(Z|[+-]\d{2}:\d{2})$/i;

function parseApiDateTime(value: string): Date {
  const raw = value.trim();
  // SQLite can drop timezone offsets; treat offset-less API datetimes as UTC.
  const normalized = ISO_TZ_SUFFIX.test(raw) ? raw : `${raw}Z`;
  return new Date(normalized);
}

export function formatLocalDateTime(
  value: string | null | undefined,
  options?: Intl.DateTimeFormatOptions,
): string {
  if (!value) {
    return '-';
  }
  const parsed = parseApiDateTime(value);
  if (Number.isNaN(parsed.getTime())) {
    return '-';
  }
  return parsed.toLocaleString(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
    ...options,
  });
}
