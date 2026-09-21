import { type StorageTier, StorageTierState, StorageTiers } from '@osac/types';

import { useApiFetch } from '../api-context';
import { cel } from '../cel';
import { type ListParams, apiQueryKey } from '../types';
import { useApiQuery } from '../use-api-query';

// Server-side CEL filter restricting the list to ACTIVE tiers. Enum fields compare
// with `==` against the int literal (see cluster-versions.ts for the enum caveat).
export const STORAGE_TIER_ACTIVE_LIST_FILTER = cel<StorageTier>((filter) =>
  filter.field('status.state').equals(StorageTierState.ACTIVE),
);

export const useStorageTiers = (params: ListParams = {}) => {
  const client = useApiFetch(StorageTiers);
  return useApiQuery({
    queryKey: apiQueryKey('v1/storage_tiers', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
  });
};

export const useStorageTier = (id: string) => {
  const client = useApiFetch(StorageTiers);
  return useApiQuery({
    queryKey: apiQueryKey('v1/storage_tiers', [id]),
    queryFn: () => client.get({ id }),
    select: (data) => data.object,
    enabled: Boolean(id),
  });
};
