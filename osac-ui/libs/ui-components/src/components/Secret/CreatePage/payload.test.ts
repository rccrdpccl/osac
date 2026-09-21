import { create } from '@bufbuild/protobuf';
import { describe, expect, it } from 'vitest';

import { SecretSchema } from '@osac/types';

import { buildSecretCreatePayload, buildSecretUpdatePayload } from './payload';
import { getSecretValues } from './values';

const values = (dataEntries: Array<{ key: string; value: string; valueType: 'text' }>) => ({
  metadata: { name: 'my-secret', project: 'my-project', description: 'foo-desc' },
  dataEntries,
});

describe('buildSecretCreatePayload', () => {
  it('preserves values for unique secret keys', () => {
    const payload = buildSecretCreatePayload(
      values([
        { key: 'username', value: 'admin', valueType: 'text' },
        { key: 'password', value: 's3cret', valueType: 'text' },
      ]),
    );

    expect(payload.data).toEqual({
      username: new TextEncoder().encode('admin'),
      password: new TextEncoder().encode('s3cret'),
    });
  });

  it('rejects duplicate secret keys before building the payload', () => {
    expect(() =>
      buildSecretCreatePayload(
        values([
          { key: 'username', value: 'admin', valueType: 'text' },
          { key: 'username', value: 'replacement', valueType: 'text' },
        ]),
      ),
    ).toThrow('Secret keys must be unique');
  });
});

describe('buildSecretUpdatePayload', () => {
  it('preserves the original bytes for unchanged text entries', () => {
    const originalValue = new Uint8Array([0xef, 0xbb, 0xbf, 0x61]);
    const secret = create(SecretSchema, {
      id: 'secret-id',
      metadata: { name: 'my-secret', project: 'my-project' },
      data: { certificate: originalValue },
    });
    const values = getSecretValues(secret);

    const payload = buildSecretUpdatePayload(values, secret);

    expect(payload.data?.certificate).toEqual(originalValue);
  });

  it('preserves binary entries in file mode', () => {
    const originalValue = new Uint8Array([0xff, 0x00, 0x80]);
    const secret = create(SecretSchema, {
      id: 'secret-id',
      metadata: { name: 'my-secret', project: 'my-project' },
      data: { certificate: originalValue },
    });
    const values = getSecretValues(secret);

    expect(values.dataEntries[0]).toMatchObject({
      valueType: 'file',
      value: originalValue,
    });

    const payload = buildSecretUpdatePayload(values, secret);

    expect(payload.data?.certificate).toEqual(originalValue);
  });

  it('encodes an edited entry as text', () => {
    const secret = create(SecretSchema, {
      id: 'secret-id',
      metadata: { name: 'my-secret', project: 'my-project' },
      data: { username: new TextEncoder().encode('admin') },
    });
    const values = getSecretValues(secret);
    values.dataEntries[0].value = 'updated';

    const payload = buildSecretUpdatePayload(values, secret);

    expect(payload.data?.username).toEqual(new TextEncoder().encode('updated'));
  });

  it('uses uploaded bytes for file entries', () => {
    const binaryValue = new Uint8Array([0xff, 0x00, 0x80]);
    const payload = buildSecretCreatePayload({
      metadata: { name: 'my-secret', project: 'my-project', description: 'foo-desc' },
      dataEntries: [{ key: 'certificate', valueType: 'file', value: binaryValue }],
    });

    expect(payload.data?.certificate).toEqual(binaryValue);
  });

  it('rejects file entries without uploaded bytes', () => {
    expect(() =>
      buildSecretCreatePayload({
        metadata: { name: 'my-secret', project: 'my-project', description: 'foo-desc' },
        dataEntries: [{ key: 'certificate', valueType: 'file' }],
      }),
    ).toThrow('Secret file is required');
  });
});
