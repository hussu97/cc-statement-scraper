import { describe, expect, it } from 'vitest';

import { extractErrorMessage, isAbortError } from '../errors';

describe('isAbortError', () => {
  it('returns true for an Error with name AbortError', () => {
    const err = new Error('The operation was aborted');
    err.name = 'AbortError';
    expect(isAbortError(err)).toBe(true);
  });

  it('returns false for a generic Error', () => {
    expect(isAbortError(new Error('network failure'))).toBe(false);
  });

  it('returns false for a string', () => {
    expect(isAbortError('AbortError')).toBe(false);
  });

  it('returns false for null', () => {
    expect(isAbortError(null)).toBe(false);
  });

  it('returns false for undefined', () => {
    expect(isAbortError(undefined)).toBe(false);
  });

  it('returns false for a plain object', () => {
    expect(isAbortError({ name: 'AbortError' })).toBe(false);
  });
});

describe('extractErrorMessage', () => {
  it('returns a plain string unchanged', () => {
    expect(extractErrorMessage('something went wrong')).toBe('something went wrong');
  });

  it('returns the message for a generic Error', () => {
    expect(extractErrorMessage(new Error('network error'))).toBe('network error');
  });

  it('extracts the detail field from a FastAPI JSON error body', () => {
    const err = new Error('HTTP 422 Unprocessable Entity: {"detail":"Value is required"}');
    expect(extractErrorMessage(err)).toBe('Value is required');
  });

  it('falls back to the full message when JSON has no detail field', () => {
    const err = new Error('HTTP 400 Bad Request: {"code":"INVALID"}');
    expect(extractErrorMessage(err)).toBe('HTTP 400 Bad Request: {"code":"INVALID"}');
  });

  it('falls back to the full message when body is not JSON', () => {
    const err = new Error('HTTP 500 Internal Server Error: plain text');
    expect(extractErrorMessage(err)).toBe('HTTP 500 Internal Server Error: plain text');
  });

  it('returns fallback for null', () => {
    expect(extractErrorMessage(null)).toBe('An unexpected error occurred');
  });

  it('returns fallback for undefined', () => {
    expect(extractErrorMessage(undefined)).toBe('An unexpected error occurred');
  });

  it('returns fallback for a plain object', () => {
    expect(extractErrorMessage({ message: 'oops' })).toBe('An unexpected error occurred');
  });
});
