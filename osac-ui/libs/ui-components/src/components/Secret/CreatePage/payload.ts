import type { MessageInitShape } from '@bufbuild/protobuf';

import { SecretSchema } from '@osac/types';
import type { Secret } from '@osac/types';

import type { SecretDataEntry, SecretValues } from './values';

const getEntryBytes = (entry: SecretDataEntry, secretData?: Secret['data']) => {
  if (entry.valueType === 'file') {
    if (!entry.value) {
      throw new Error('Secret file is required');
    }

    return entry.value;
  }

  const serverValue = secretData?.[entry.key];
  if (serverValue !== undefined) {
    try {
      if (new TextDecoder('utf-8', { fatal: true }).decode(serverValue) === entry.value) {
        return serverValue;
      }
    } catch {
      // Invalid UTF-8 entries are represented as files and handled above.
    }
  }

  return new TextEncoder().encode(entry.value);
};

const buildData = (entries: SecretValues['dataEntries'], secretData?: Secret['data']) => {
  const keys = entries.map(({ key }) => key);
  if (new Set(keys).size !== keys.length) {
    throw new Error('Secret keys must be unique');
  }

  return Object.fromEntries(entries.map((entry) => [entry.key, getEntryBytes(entry, secretData)]));
};

export const buildSecretCreatePayload = (
  values: SecretValues,
): MessageInitShape<typeof SecretSchema> => ({
  metadata: {
    name: values.metadata.name,
    project: values.metadata.project,
    description: values.metadata.description,
  },
  data: buildData(values.dataEntries),
});

export const buildSecretUpdatePayload = (
  values: SecretValues,
  secret: Secret,
): MessageInitShape<typeof SecretSchema> => ({
  metadata: {
    description: values.metadata.description,
  },
  data: buildData(values.dataEntries, secret.data),
});
