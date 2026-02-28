import { describe, expect, it, vi } from 'vitest';

import { formatLocalDateTime } from '../datetime';

describe('formatLocalDateTime', () => {
  it('returns "-" for null', () => {
    expect(formatLocalDateTime(null)).toBe('-');
  });

  it('returns "-" for undefined', () => {
    expect(formatLocalDateTime(undefined)).toBe('-');
  });

  it('returns "-" for an empty string', () => {
    expect(formatLocalDateTime('')).toBe('-');
  });

  it('returns "-" for an unparseable string', () => {
    expect(formatLocalDateTime('not-a-date')).toBe('-');
  });

  it('parses an ISO string with UTC offset and returns a non-empty string', () => {
    const result = formatLocalDateTime('2025-03-15T10:30:00Z');
    expect(result).not.toBe('-');
    expect(typeof result).toBe('string');
    expect(result.length).toBeGreaterThan(0);
  });

  it('treats offset-less datetimes as UTC (no crash)', () => {
    // SQLite may return datetimes without timezone info
    const result = formatLocalDateTime('2025-03-15T10:30:00');
    expect(result).not.toBe('-');
  });

  it('parses ISO string with explicit positive UTC offset', () => {
    const result = formatLocalDateTime('2025-06-01T08:00:00+04:00');
    expect(result).not.toBe('-');
  });

  it('applies custom Intl.DateTimeFormatOptions', () => {
    // Request only the year — result should differ from the default
    const withYear = formatLocalDateTime('2025-01-01T00:00:00Z', {
      year: 'numeric',
      dateStyle: undefined,
      timeStyle: undefined,
    });
    expect(withYear).toContain('2025');
  });
});
