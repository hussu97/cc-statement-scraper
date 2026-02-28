import { describe, expect, it } from 'vitest';

import { isAbortError } from '../errors';

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
