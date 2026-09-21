import { type HostType, HostTypes } from '@osac/types';

import { useApiFetch } from '../api-context';
import { type ListParams, apiQueryKey } from '../types';
import { resourceDisplayName } from './networking';
import { useApiQuery } from '../use-api-query';

type HostTypesQueryOptions = {
  enabled?: boolean;
};

export const useHostTypes = (params: ListParams = {}, options: HostTypesQueryOptions = {}) => {
  const client = useApiFetch(HostTypes);
  return useApiQuery({
    queryKey: apiQueryKey('v1/host_types', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
    enabled: options.enabled ?? true,
  });
};

export const useHostType = (id: string | undefined) => {
  const client = useApiFetch(HostTypes);
  return useApiQuery({
    queryKey: apiQueryKey('v1/host_types', id ? [id] : undefined),
    queryFn: () => client.get({ id: id ?? '' }),
    select: (data) => data.object,
    enabled: Boolean(id),
  });
};

export const hostTypeDisplayName = (hostType: HostType): string =>
  hostType.title?.trim() || resourceDisplayName(hostType.metadata, hostType.id);
