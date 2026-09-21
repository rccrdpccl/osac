import { describe, expect, it } from 'vitest';

import { Architecture, GuestOSFamily } from '@osac/types';

import { getDiskImageCreateSchema } from './validation';
import { tIdentity as t } from '../../test-utils/i18n';

const validValues = {
  metadata: { name: 'rhel-9' },
  spec: {
    sourceRef: 'quay.io/example/rhel:9',
    guestOsFamily: GuestOSFamily.GUEST_OS_FAMILY_LINUX,
    architecture: [Architecture.AMD64],
  },
};

describe('getDiskImageCreateSchema', () => {
  const schema = getDiskImageCreateSchema(t);

  it('accepts valid values', async () => {
    await expect(schema.isValid(validValues)).resolves.toBe(true);
  });

  it('rejects a blank name', async () => {
    await expect(schema.isValid({ ...validValues, metadata: { name: '' } })).resolves.toBe(false);
  });

  it('rejects an empty source reference', async () => {
    await expect(
      schema.isValid({ ...validValues, spec: { ...validValues.spec, sourceRef: '' } }),
    ).resolves.toBe(false);
  });

  it('rejects an empty architecture selection', async () => {
    await expect(
      schema.isValid({ ...validValues, spec: { ...validValues.spec, architecture: [] } }),
    ).resolves.toBe(false);
  });

  it('accepts multiple architectures', async () => {
    await expect(
      schema.isValid({
        ...validValues,
        spec: { ...validValues.spec, architecture: [Architecture.AMD64, Architecture.ARM64] },
      }),
    ).resolves.toBe(true);
  });
});
