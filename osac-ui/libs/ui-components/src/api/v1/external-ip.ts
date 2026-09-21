import { type Client } from '@connectrpc/connect';
import { useMutation } from '@tanstack/react-query';

import { ExternalIPAttachments, ExternalIPPools, ExternalIPState, ExternalIPs } from '@osac/types';

import { invalidateComputeInstancesQueries } from './compute-instance';
import { useApiFetch } from '../api-context';
import { type ListParams, apiQueryKey } from '../types';
import { useApiQuery, useApiQueryClient } from '../use-api-query';

export const EXTERNAL_IP_ALLOCATION_POLL_MS = 500;
export const EXTERNAL_IP_ALLOCATION_POLL_MAX_ATTEMPTS = 20;

export const pollExternalIpUntilAllocated = async (
  externalIpsClient: Client<typeof ExternalIPs>,
  id: string,
) => {
  for (let attempt = 0; attempt < EXTERNAL_IP_ALLOCATION_POLL_MAX_ATTEMPTS; attempt++) {
    const resp = await externalIpsClient.get({ id });
    if (!resp.object) {
      throw new Error('External IP not found in response');
    }
    const externalIp = resp.object;
    const state = externalIp.status?.state;
    if (state === ExternalIPState.EXTERNAL_IP_STATE_ALLOCATED) {
      return externalIp;
    }
    if (state === ExternalIPState.EXTERNAL_IP_STATE_FAILED) {
      throw new Error(externalIp.status?.message || 'External IP allocation failed');
    }
    await new Promise((resolve) => setTimeout(resolve, EXTERNAL_IP_ALLOCATION_POLL_MS));
  }
  throw new Error('Timed out waiting for the external IP to be allocated');
};

export type AttachExternalIpInput = {
  computeInstanceId: string;
  pool: string;
};

export const useAttachExternalIp = () => {
  const externalIpsClient = useApiFetch(ExternalIPs);
  const attachmentsClient = useApiFetch(ExternalIPAttachments);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: async ({ computeInstanceId, pool }: AttachExternalIpInput) => {
      const createResp = await externalIpsClient.create({
        object: { spec: { pool: { id: pool } } },
      });
      if (!createResp.object) {
        throw new Error('External IP not found in response');
      }
      const created = createResp.object;

      let allocated;
      try {
        allocated = await pollExternalIpUntilAllocated(externalIpsClient, created.id);
      } catch (err) {
        await externalIpsClient.delete({ id: created.id }).catch(() => undefined);
        throw err;
      }

      try {
        const attachResp = await attachmentsClient.create({
          object: {
            spec: {
              externalIp: {
                id: allocated.id,
              },
              target: { case: 'computeInstance', value: { id: computeInstanceId } },
            },
          },
        });
        return attachResp.object;
      } catch (err) {
        await externalIpsClient.delete({ id: allocated.id }).catch(() => undefined);
        throw err;
      }
    },
    onSuccess: () => invalidateComputeInstancesQueries(qc),
  });
};

export const useExternalIPPools = (params: ListParams = {}) => {
  const client = useApiFetch(ExternalIPPools);
  return useApiQuery({
    queryKey: apiQueryKey('v1/external_ip_pools', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
  });
};

type ExternalIPQueryOptions = {
  enabled?: boolean;
};

export const useExternalIPs = (params: ListParams = {}, options: ExternalIPQueryOptions = {}) => {
  const client = useApiFetch(ExternalIPs);
  return useApiQuery({
    queryKey: apiQueryKey('v1/external_ips', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
    enabled: options.enabled ?? true,
  });
};

export const useExternalIPAttachments = (
  params: ListParams = {},
  options: ExternalIPQueryOptions = {},
) => {
  const client = useApiFetch(ExternalIPAttachments);
  return useApiQuery({
    queryKey: apiQueryKey('v1/external_ip_attachments', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
    enabled: options.enabled ?? true,
  });
};
