import { describe, expect, it } from 'vitest';
import { ValidationError } from 'yup';

import { positiveIntegerSchema } from './positive-integer';
import { tIdentity as t } from '../test-utils/i18n';

const validate = async (value: string, max?: number) => {
  const schema = positiveIntegerSchema(t, max);
  try {
    await schema.validate(value);
    return undefined;
  } catch (error) {
    if (error instanceof ValidationError) {
      return error.message;
    }
    throw error;
  }
};

describe('positiveIntegerSchema', () => {
  it.each([
    ['1', undefined],
    ['42', undefined],
    ['1000000', undefined],
  ])('accepts positive integer %s', async (value, expected) => {
    await expect(validate(value)).resolves.toBe(expected);
  });

  it.each([
    ['', 'This field is required'],
    ['0', 'Must be greater than zero'],
    ['-1', 'Must be greater than zero'],
    ['1.5', 'Must be a whole number'],
    ['abc', 'Must be a whole number'],
  ])('rejects invalid value %s', async (value, expectedMessage) => {
    await expect(validate(value)).resolves.toBe(expectedMessage);
  });

  it('accepts a value at the optional max bound', async () => {
    await expect(validate('100', 100)).resolves.toBeUndefined();
  });

  it('rejects a value above the optional max bound', async () => {
    await expect(validate('101', 100)).resolves.toBe('Must be at most {{max}}');
  });
});
