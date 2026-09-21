import React, { type ReactNode, createElement } from 'react';
import { create } from '@bufbuild/protobuf';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { IdentityProviderSchema, IdentityProviders } from '@osac/types';
import { TenantSchema, Tenants } from '@osac/types/private';

import { ApiProvider } from './api-context';
import {
  useCreateResource,
  useDeleteResource,
  useGetResource,
  useListResource,
  useUpdateResource,
} from './use-resource';
import { createMockConnectTransport } from '../test-utils/createMockConnectTransport';

const makeTenant = (id: string) =>
  create(TenantSchema, {
    id,
    metadata: { name: `tenant-${id}` },
    spec: { domains: [`${id}.example.com`] },
  });

const makeIdentityProvider = (id: string) =>
  create(IdentityProviderSchema, {
    id,
    spec: { title: `Identity provider ${id}`, enabled: true },
  });

const makeWrapper = (transport: ReturnType<typeof createMockConnectTransport>) => {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const wrapper = ({ children }: { children: ReactNode }) =>
    createElement(
      ApiProvider,
      { transport } as React.ComponentProps<typeof ApiProvider>,
      createElement(QueryClientProvider, { client: queryClient }, children),
    );
  return { wrapper, queryClient };
};

describe('resource queries', () => {
  it('lists resources with an inferred response type', async () => {
    const transport = createMockConnectTransport({
      tenants: [makeTenant('tenant-1'), makeTenant('tenant-2')],
    });
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useListResource(Tenants), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.items.map((tenant) => tenant.id)).toEqual(['tenant-1', 'tenant-2']);
  });

  it('gets a resource with inferred request and response types', async () => {
    const transport = createMockConnectTransport({
      identityProviders: [makeIdentityProvider('idp-1')],
    });
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useGetResource(IdentityProviders, { id: 'idp-1' }), {
      wrapper,
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.object?.id).toBe('idp-1');
  });
});

describe('resource mutations', () => {
  it('calls create, update, and delete and invalidates every query for the service', async () => {
    const transport = createMockConnectTransport();
    const { wrapper, queryClient } = makeWrapper(transport);
    const listKey = [IdentityProviders.typeName, 'list', {}] as const;
    queryClient.setQueryData(listKey, { items: [] });
    const { result } = renderHook(
      () => ({
        create: useCreateResource(IdentityProviders),
        update: useUpdateResource(IdentityProviders),
        delete: useDeleteResource(IdentityProviders),
      }),
      { wrapper },
    );

    await act(async () => {
      await result.current.create.mutateAsync({ object: makeIdentityProvider('created') });
    });
    expect(queryClient.getQueryState(listKey)?.isInvalidated).toBe(true);

    await act(async () => {
      await result.current.update.mutateAsync({ object: makeIdentityProvider('updated') });
      await result.current.delete.mutateAsync({ id: 'updated' });
    });

    expect(result.current.create.data?.object?.id).toBe('created');
    expect(result.current.update.data?.object?.id).toBe('updated');
    expect(result.current.delete.isSuccess).toBe(true);
  });
});
