import { type InstanceType, InstanceTypeState, InstanceTypes } from '@osac/types';

import { useApiFetch } from '../api-context';
import { cel } from '../cel';
import { type ListParams, apiQueryKey } from '../types';
import { useApiQuery } from '../use-api-query';

type InstanceTypesQueryOptions = {
  enabled?: boolean;
};

export const INSTANCE_TYPE_ACTIVE_LIST_FILTER = cel<InstanceType>((filter) =>
  filter.field('spec.state').equals(InstanceTypeState.ACTIVE),
);

export const useInstanceTypes = (
  params: ListParams = {},
  options: InstanceTypesQueryOptions = {},
) => {
  const client = useApiFetch(InstanceTypes);
  return useApiQuery({
    queryKey: apiQueryKey('v1/instance_types', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
    enabled: options.enabled ?? true,
  });
};

export const useInstanceType = (id: string | undefined) => {
  const client = useApiFetch(InstanceTypes);
  const trimmedId = id?.trim() ?? '';
  return useApiQuery({
    queryKey: apiQueryKey('v1/instance_types', trimmedId ? [trimmedId] : undefined),
    queryFn: () => client.get({ id: trimmedId }),
    select: (data) => data.object,
    enabled: Boolean(trimmedId),
  });
};
