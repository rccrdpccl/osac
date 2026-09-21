import { ClusterTemplates } from '@osac/types';

import { useApiFetch } from '../api-context';
import { apiQueryKey } from '../types';
import { useApiQuery } from '../use-api-query';

export const useClusterTemplate = (id: string | undefined) => {
  const client = useApiFetch(ClusterTemplates);
  return useApiQuery({
    queryKey: apiQueryKey('v1/cluster_templates', id ? [id] : undefined),
    queryFn: () => client.get({ id: id ?? '' }),
    select: (data) => data.object,
    enabled: Boolean(id),
  });
};
