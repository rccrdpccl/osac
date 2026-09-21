import { type MessageInitShape } from '@bufbuild/protobuf';
import { timestampNow } from '@bufbuild/protobuf/wkt';
import { keepPreviousData, useMutation } from '@tanstack/react-query';

import {
  type ComputeInstance,
  ComputeInstanceSchema,
  ComputeInstanceState,
  ComputeInstances,
  type ComputeInstancesListResponse,
} from '@osac/types';
import { ComputeInstanceRunStrategy } from '@osac/types';
import { useProjectFilterQuery } from '@osac/ui-components/hooks/use-project-filter-query';

import { useApiFetch } from '../api-context';
import { apiQueryKey } from '../types';
import { buildUpdateMaskPaths } from './update-mask';
import { type ApiQueryClient, useApiQuery, useApiQueryClient } from '../use-api-query';

export const useComputeInstances = () => {
  const client = useApiFetch(ComputeInstances);
  const filter = useProjectFilterQuery<ComputeInstance>();
  return useApiQuery({
    queryKey: apiQueryKey('v1/compute_instances', undefined, filter ? { filter } : undefined),
    queryFn: () => client.list({ filter }),
    select: (data) => data.items,
    placeholderData: keepPreviousData,
  });
};

export const useComputeInstance = (id: string) => {
  const client = useApiFetch(ComputeInstances);
  const trimmedId = id?.trim() ?? '';
  return useApiQuery({
    queryKey: apiQueryKey('v1/compute_instances', [trimmedId]),
    queryFn: () => client.get({ id: trimmedId }),
    select: (data) => data.object,
    enabled: Boolean(trimmedId),
  });
};

export const invalidateComputeInstancesQueries = async (qc: ApiQueryClient) => {
  await qc.invalidateQueries({ queryKey: apiQueryKey('v1/compute_instances') });
};

export const POST_CREATE_LIST_POLL_MS = 500;
export const POST_CREATE_LIST_POLL_MAX_ATTEMPTS = 20;

export const pollComputeInstancesUntilListed = async (
  qc: ApiQueryClient,
  instanceId: string,
  signal?: { cancelled: boolean },
): Promise<void> => {
  for (let attempt = 0; attempt < POST_CREATE_LIST_POLL_MAX_ATTEMPTS; attempt++) {
    if (signal?.cancelled) {
      return;
    }
    await invalidateComputeInstancesQueries(qc);
    const data = qc.getQueryData<ComputeInstancesListResponse>(apiQueryKey('v1/compute_instances'));
    if (data?.items?.some((v) => v.id === instanceId)) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, POST_CREATE_LIST_POLL_MS));
  }
};

export const useProvisionComputeInstance = () => {
  const client = useApiFetch(ComputeInstances);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: (vm: MessageInitShape<typeof ComputeInstanceSchema>) =>
      client.create({ object: vm }).then((r) => r.object),
    onSuccess: async () => {
      await invalidateComputeInstancesQueries(qc);
    },
  });
};

export type ComputeInstancePowerAction = 'start' | 'stop' | 'restart';

export type PatchComputeInstanceInput = {
  id: string;
  powerAction: ComputeInstancePowerAction;
};

const buildPowerPatchBody = (
  powerAction: ComputeInstancePowerAction,
): MessageInitShape<typeof ComputeInstanceSchema> => {
  switch (powerAction) {
    case 'stop':
      return {
        spec: { runStrategy: ComputeInstanceRunStrategy.COMPUTE_INSTANCE_RUN_STRATEGY_HALTED },
        status: { state: ComputeInstanceState.STOPPED },
      };
    case 'start':
      return {
        spec: { runStrategy: ComputeInstanceRunStrategy.COMPUTE_INSTANCE_RUN_STRATEGY_ALWAYS },
        status: { state: ComputeInstanceState.RUNNING },
      };
    case 'restart':
      return { spec: { restartRequestedAt: timestampNow() } };
  }
};

export const usePatchComputeInstance = () => {
  const client = useApiFetch(ComputeInstances);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: ({ id, powerAction }: PatchComputeInstanceInput) => {
      const body = buildPowerPatchBody(powerAction);
      return client
        .update({
          object: { id, ...body },
          updateMask: { paths: buildUpdateMaskPaths(body as Record<string, unknown>) },
        })
        .then((r) => r.object);
    },
    onSuccess: () => invalidateComputeInstancesQueries(qc),
  });
};

export const useDeleteComputeInstance = () => {
  const client = useApiFetch(ComputeInstances);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: (id: string) => client.delete({ id }),
    onSuccess: () => invalidateComputeInstancesQueries(qc),
  });
};
