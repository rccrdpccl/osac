import { type MessageInitShape } from '@bufbuild/protobuf';
import { useMutation } from '@tanstack/react-query';

import { type Project, type ProjectSchema, Projects } from '@osac/types';

import { useApiFetch } from '../api-context';
import { cel } from '../cel';
import { type ListParams, apiQueryKey } from '../types';
import { type ApiQueryClient, useApiQuery, useApiQueryClient } from '../use-api-query';

const invalidateProjectQueries = (qc: ApiQueryClient) =>
  qc.invalidateQueries({ queryKey: apiQueryKey('v1/projects') });

export const useProjects = (
  params: ListParams = {
    filter: cel<Project>((filter) => filter.field('metadata.tenant').notEquals('shared')),
  },
) => {
  const client = useApiFetch(Projects);
  return useApiQuery({
    queryKey: apiQueryKey('v1/projects', undefined, params),
    queryFn: () => client.list(params),
    select: (data) => data.items,
  });
};

const ALL_PROJECTS_PAGE_SIZE = 100;

/**
 * Loads every project across all pages, following pagination until the full
 * collection has been fetched. `isLoading` stays true until all pages are
 * loaded — the resolved data always contains the complete set of projects.
 */
export const useAllProjects = (
  params: ListParams = {
    filter: cel<Project>((filter) => filter.field('metadata.tenant').notEquals('shared')),
  },
) => {
  const client = useApiFetch(Projects);
  return useApiQuery({
    queryKey: apiQueryKey('v1/projects', ['all'], params),
    queryFn: async () => {
      const items: Project[] = [];
      let offset = 0;
      let total = Infinity;
      while (items.length < total) {
        const page = await client.list({ ...params, limit: ALL_PROJECTS_PAGE_SIZE, offset });
        items.push(...page.items);
        total = page.total;
        if (page.items.length === 0) {
          break;
        }
        offset += page.items.length;
      }
      return items;
    },
  });
};

export const useProject = (id?: string) => {
  const client = useApiFetch(Projects);
  return useApiQuery({
    queryKey: apiQueryKey('v1/projects', [id]),
    queryFn: () => client.get({ id }),
    select: (data) => {
      if (!data.object) {
        throw new Error('Get response missing project object');
      }
      return data.object;
    },
    enabled: !!id,
  });
};

export const useCreateProject = () => {
  const client = useApiFetch(Projects);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: async (body: MessageInitShape<typeof ProjectSchema>) => {
      const resp = await client.create({ object: body });
      if (!resp.object) {
        throw new Error('Create response missing project object');
      }
      return resp.object;
    },
    onSuccess: () => invalidateProjectQueries(qc),
  });
};

export const useDeleteProject = () => {
  const client = useApiFetch(Projects);
  const qc = useApiQueryClient();
  return useMutation({
    mutationFn: (id: string) => client.delete({ id }),
    onSuccess: () => invalidateProjectQueries(qc),
  });
};
