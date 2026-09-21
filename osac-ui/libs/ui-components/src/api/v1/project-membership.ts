import { type MessageInitShape } from '@bufbuild/protobuf';
import { useMutation } from '@tanstack/react-query';

import { type ProjectMembershipSchema, ProjectMemberships } from '@osac/types';

import { useApiFetch } from '../api-context';
import { type ListParams, apiQueryKey } from '../types';
import { type ApiQueryClient, useApiQuery, useApiQueryClient } from '../use-api-query';
import { buildUpdateMaskPaths } from './update-mask';

const invalidateProjectMembershipQueries = (qc: ApiQueryClient) =>
  qc.invalidateQueries({ queryKey: apiQueryKey('v1/project_memberships') });

export const useProjectMemberships = (params: ListParams = {}) => {
  const client = useApiFetch(ProjectMemberships);
  return useApiQuery({
    queryKey: apiQueryKey('v1/project_memberships', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
  });
};

export const useProjectMembership = (id?: string) => {
  const client = useApiFetch(ProjectMemberships);
  return useApiQuery({
    queryKey: apiQueryKey('v1/project_memberships', [id]),
    queryFn: () => client.get({ id }),
    select: (data) => {
      if (!data.object) {
        throw new Error('Get response missing project membership object');
      }
      return data.object;
    },
    enabled: !!id,
  });
};

export const useCreateProjectMembership = () => {
  const client = useApiFetch(ProjectMemberships);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: async (body: MessageInitShape<typeof ProjectMembershipSchema>) => {
      const resp = await client.create({ object: body });
      if (!resp.object) {
        throw new Error('Create response missing project membership object');
      }
      return resp.object;
    },
    onSuccess: () => invalidateProjectMembershipQueries(qc),
  });
};

export const useDeleteProjectMembership = () => {
  const client = useApiFetch(ProjectMemberships);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: (id: string) => client.delete({ id }),
    onSuccess: () => invalidateProjectMembershipQueries(qc),
  });
};

export const useUpdateProjectMembership = () => {
  const client = useApiFetch(ProjectMemberships);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: async ({
      id,
      body,
    }: {
      id: string;
      body: MessageInitShape<typeof ProjectMembershipSchema>;
    }) => {
      const resp = await client.update({
        object: {
          id,
          ...body,
        },
        updateMask: {
          paths: buildUpdateMaskPaths(body),
        },
      });
      if (!resp.object) {
        throw new Error('Update response missing project membership object');
      }
      return resp.object;
    },
    onSuccess: () => invalidateProjectMembershipQueries(qc),
  });
};
