import { Secret } from '@osac/types';

export const SECRET_FILE_MAX_BYTES = 1024 * 1024;

export interface SecretValues {
  metadata: {
    project: string;
    name: string;
    description: string;
  };
  dataEntries: SecretDataEntry[];
}

export type SecretDataEntry = SecretTextDataEntry | SecretFileDataEntry;

export interface SecretTextDataEntry {
  key: string;
  valueType: 'text';
  value: string;
}

export interface SecretFileDataEntry {
  key: string;
  valueType: 'file';
  value?: Uint8Array;
}

export type SecretDataEntryValueType = 'text' | 'file';

const getDataEntries = (data: Secret['data']): SecretDataEntry[] => {
  const decoder = new TextDecoder('utf-8', { fatal: true });

  return Object.entries(data).map(([key, value]) => {
    try {
      const text = decoder.decode(value);

      return {
        key,
        value: text,
        valueType: 'text',
      };
    } catch {
      return {
        key,
        valueType: 'file',
        value: new Uint8Array(value),
      };
    }
  });
};

export const getSecretValues = (secret?: Secret): SecretValues => {
  if (secret) {
    return {
      metadata: {
        project: secret.metadata?.project || '',
        name: secret.metadata?.name || '',
        description: secret.metadata?.description || '',
      },
      dataEntries: getDataEntries(secret.data),
    };
  }

  return {
    metadata: {
      name: '',
      project: '',
      description: '',
    },
    dataEntries: [{ key: '', valueType: 'text', value: '' }],
  };
};
