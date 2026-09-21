import { TFunction } from 'i18next';

import { Secret } from '@osac/types';

const SECRET_TYPE_LABEL = 'osac.openshift.io/secret-type';

export const getSecretType = (secret: Secret, t: TFunction) => {
  return secret.metadata?.labels[SECRET_TYPE_LABEL] || t('Generic');
};

export const downloadSecretBytes = (bytes: Uint8Array, filename: string) => {
  const blobBytes = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(blobBytes).set(bytes);
  const url = URL.createObjectURL(new Blob([blobBytes], { type: 'application/octet-stream' }));
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
};
