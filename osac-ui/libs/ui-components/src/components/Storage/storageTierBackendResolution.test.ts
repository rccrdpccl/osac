import { type TFunction } from 'i18next';
import { describe, expect, it } from 'vitest';

import type { StorageTier } from '@osac/types/private';
import { StorageProtocol } from '@osac/types/private';

import { protocolLabel, uniqueBackendIds } from './storageTierBackendResolution';

const t = ((key: string) => key) as TFunction;

const makeTier = (id: string, backendIds: string[]): StorageTier =>
  ({
    id,
    spec: { backends: backendIds.map((backendId) => ({ backendId })) },
  }) as StorageTier;

describe('protocolLabel', () => {
  it('maps NFS to its label', () => {
    expect(protocolLabel(t)[StorageProtocol.NFS]).toBe('NFS');
  });

  it('maps BLOCK to its label', () => {
    expect(protocolLabel(t)[StorageProtocol.BLOCK]).toBe('Block');
  });

  it('maps UNSPECIFIED to an em dash', () => {
    expect(protocolLabel(t)[StorageProtocol.UNSPECIFIED]).toBe('—');
  });
});

describe('uniqueBackendIds', () => {
  it('returns an empty array for no tiers', () => {
    expect(uniqueBackendIds([])).toEqual([]);
  });

  it('dedupes and sorts backend ids across multiple tiers', () => {
    const tiers = [
      makeTier('tier-1', ['backend-b', 'backend-a']),
      makeTier('tier-2', ['backend-a']),
    ];

    expect(uniqueBackendIds(tiers)).toEqual(['backend-a', 'backend-b']);
  });
});
