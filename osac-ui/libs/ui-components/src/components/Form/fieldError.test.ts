import type { FieldMetaProps } from 'formik';
import { describe, expect, it } from 'vitest';

import { getVisibleFieldError } from './fieldError';

describe('getVisibleFieldError', () => {
  const meta = (touched: boolean, error?: string): FieldMetaProps<unknown> =>
    ({ touched, error }) as FieldMetaProps<unknown>;

  it('shows error when field is touched', () => {
    expect(getVisibleFieldError(meta(true, 'Name is required'), false)).toBe('Name is required');
  });

  it('shows error when step validation is active even if field is untouched', () => {
    expect(getVisibleFieldError(meta(false, 'Name is required'), true)).toBe('Name is required');
  });

  it('shows a nested id error when step validation is active', () => {
    const objectMeta = {
      touched: false,
      error: { id: 'Tenant is required' },
    } as unknown as FieldMetaProps<unknown>;
    expect(getVisibleFieldError(objectMeta, true)).toBe('Tenant is required');
  });

  it('hides error when field is untouched and step validation is inactive', () => {
    expect(getVisibleFieldError(meta(false, 'Name is required'), false)).toBeUndefined();
  });
});
