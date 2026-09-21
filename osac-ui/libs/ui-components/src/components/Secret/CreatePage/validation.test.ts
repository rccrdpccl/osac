import { describe, expect, it } from 'vitest';

import { getSecretValidationSchema } from './validation';
import { SECRET_FILE_MAX_BYTES } from './values';
import { tIdentity as t } from '../../../test-utils/i18n';

const validValues = {
  metadata: { name: 'my-secret', project: 'my-project' },
  dataEntries: [{ key: 'username', value: 'admin', valueType: 'text' }],
};

describe('getSecretValidationSchema', () => {
  const schema = getSecretValidationSchema(t, false);

  it('accepts unique secret keys', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        dataEntries: [
          { key: 'username', value: 'admin', valueType: 'text' },
          { key: 'password', value: 's3cret', valueType: 'text' },
        ],
      }),
    ).resolves.toBe(true);
  });

  it('rejects duplicate secret keys', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        dataEntries: [
          { key: 'username', value: 'admin', valueType: 'text' },
          { key: 'username', value: 'replacement', valueType: 'text' },
        ],
      }),
    ).resolves.toBe(false);
  });

  it('preserves required validation for empty keys', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        dataEntries: [{ key: '', value: 'admin', valueType: 'text' }],
      }),
    ).resolves.toBe(false);
  });

  it('accepts file entries with uploaded bytes', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        dataEntries: [
          {
            key: 'certificate',
            valueType: 'file',
            value: new Uint8Array([0xff]),
          },
        ],
      }),
    ).resolves.toBe(true);
  });

  it('rejects file entries without uploaded bytes', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        dataEntries: [{ key: 'certificate', valueType: 'file' }],
      }),
    ).resolves.toBe(false);
  });

  it('rejects file entries larger than the upload limit', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        dataEntries: [
          {
            key: 'certificate',
            valueType: 'file',
            value: new Uint8Array(SECRET_FILE_MAX_BYTES + 1),
          },
        ],
      }),
    ).resolves.toBe(false);
  });

  it('accepts file entries at the upload limit', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        dataEntries: [
          {
            key: 'certificate',
            valueType: 'file',
            value: new Uint8Array(SECRET_FILE_MAX_BYTES),
          },
        ],
      }),
    ).resolves.toBe(true);
  });
});
