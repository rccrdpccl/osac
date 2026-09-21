import { describe, expect, it } from 'vitest';
import { ValidationError } from 'yup';

import { resourceNameSchema } from './resource-name';
import { tIdentity as t } from '../test-utils/i18n';

const validateName = async (name: string) => {
  const schema = resourceNameSchema(t);
  try {
    await schema.validate(name);
    return undefined;
  } catch (error) {
    if (error instanceof ValidationError) {
      return error.message;
    }
    throw error;
  }
};

describe('buildMetadataNameSchema', () => {
  it.each([
    ['my-cluster', undefined],
    ['web-vm-1', undefined],
    ['a', undefined],
    ['a23456789012345678901234567890123456789012345678901234567890123', undefined],
  ])('accepts valid DNS label %s', async (name, expected) => {
    await expect(validateName(name)).resolves.toBe(expected);
  });

  it.each([
    ['', 'Name is required'],
    [
      'a234567890123456789012345678901234567890123456789012345678901234',
      'Name must be at most 63 characters long',
    ],
    ['    ', 'Name must only contain lowercase letters (a-z), digits (0-9), and hyphens (-)'],
    ['MyVM', 'Name must only contain lowercase letters (a-z), digits (0-9), and hyphens (-)'],
    ['my_vm', 'Name must only contain lowercase letters (a-z), digits (0-9), and hyphens (-)'],
    ['-myvm', 'Name cannot start with a hyphen'],
    ['myvm-', 'Name cannot end with a hyphen'],
  ])('rejects invalid name %s', async (name, expectedMessage) => {
    await expect(validateName(name)).resolves.toBe(expectedMessage);
  });
});
