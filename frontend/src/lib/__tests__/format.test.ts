import { describe, expect, it } from 'vitest';

import { formatAmount } from '../format';

describe('formatAmount', () => {
  it('formats integers with two decimal places', () => {
    expect(formatAmount(1000)).toBe('1,000.00');
  });

  it('formats decimals with two decimal places', () => {
    expect(formatAmount(1234.5)).toBe('1,234.50');
  });

  it('rounds to two decimal places', () => {
    expect(formatAmount(9.999)).toBe('10.00');
  });

  it('formats zero', () => {
    expect(formatAmount(0)).toBe('0.00');
  });

  it('formats negative amounts', () => {
    expect(formatAmount(-250.75)).toBe('-250.75');
  });

  it('formats large amounts with comma separators', () => {
    expect(formatAmount(1000000)).toBe('1,000,000.00');
  });
});
