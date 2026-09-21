import type { TFunction } from 'i18next';

import type { StorageTier } from '@osac/types/private';
import { StorageProtocol } from '@osac/types/private';

export const protocolLabel = (t: TFunction): Record<StorageProtocol, string> => ({
  [StorageProtocol.UNSPECIFIED]: '—',
  [StorageProtocol.NFS]: t('NFS'),
  [StorageProtocol.BLOCK]: t('Block'),
});

export const uniqueBackendIds = (tiers: StorageTier[]): string[] => {
  const ids = new Set<string>();
  tiers.forEach((tier) => {
    tier.spec?.backends.forEach((backend) => ids.add(backend.backendId));
  });
  return Array.from(ids).sort();
};
