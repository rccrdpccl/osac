import React, { type ReactNode, createElement } from 'react';
import { create } from '@bufbuild/protobuf';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { act, renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import {
  InstanceTypeSchema,
  InstanceTypeState,
  InstanceTypesCreateResponseSchema,
  InstanceTypesUpdateResponseSchema,
  type InstanceType as PrivateInstanceType,
} from '@osac/types/private';

import {
  invalidateInstanceTypesQueries,
  useAdminInstanceTypes,
  useCreateInstanceType,
  useDeleteInstanceType,
  useUpdateInstanceType,
} from './instance-type';
import { createMockConnectTransport } from '../../../test-utils/createMockConnectTransport';
import { ApiProvider } from '../../api-context';

const makeInstanceType = (
  id: string,
  state: InstanceTypeState = InstanceTypeState.ACTIVE,
): PrivateInstanceType =>
  create(InstanceTypeSchema, {
    id,
    metadata: { name: `instance-type-${id}` },
    spec: {
      description: `${id} description`,
      cores: 4,
      memoryGib: 16,
      state,
    },
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

describe('useAdminInstanceTypes', () => {
  it('returns all private instance type items from the list response', async () => {
    const transport = createMockConnectTransport({
      privateInstanceTypes: [
        makeInstanceType('active-1', InstanceTypeState.ACTIVE),
        makeInstanceType('deprecated-1', InstanceTypeState.DEPRECATED),
      ],
    });
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useAdminInstanceTypes(), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.map((item) => item.id)).toEqual(['active-1', 'deprecated-1']);
  });

  it('stores query results under the private instance type cache key', async () => {
    const transport = createMockConnectTransport({
      privateInstanceTypes: [makeInstanceType('active-1')],
    });
    const { wrapper, queryClient } = makeWrapper(transport);
    const { result } = renderHook(() => useAdminInstanceTypes(), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(queryClient.getQueryData(['v1/private/instance_types'])).toBeDefined();
    expect(queryClient.getQueryData(['v1/instance_types'])).toBeUndefined();
  });
});

describe('useCreateInstanceType', () => {
  it('creates an instance type and invalidates the list query', async () => {
    let captured: Record<string, unknown> | undefined;
    const transport = createMockConnectTransport(
      {},
      {
        onInstanceTypeCreate: (req) => {
          captured = req as unknown as Record<string, unknown>;
          return create(InstanceTypesCreateResponseSchema, {
            object: makeInstanceType('new-it'),
          });
        },
      },
    );
    const { wrapper, queryClient } = makeWrapper(transport);
    queryClient.setQueryData(['v1/private/instance_types'], { items: [] });
    const { result } = renderHook(() => useCreateInstanceType(), { wrapper });

    act(() => {
      result.current.mutate({
        metadata: { name: 'new-it' },
        spec: { cores: 4, memoryGib: 16, description: 'new-it description' },
      });
    });

    await waitFor(() => expect(result.current.isSuccess || result.current.isError).toBe(true));
    expect(result.current.isSuccess).toBe(true);
    expect(result.current.data?.id).toBe('new-it');
    const object = captured?.object as { metadata?: { name?: string } };
    expect(object.metadata?.name).toBe('new-it');
    expect(queryClient.getQueryState(['v1/private/instance_types'])?.isInvalidated).toBe(true);
  });

  it('rejects when the create response is missing an object', async () => {
    const transport = createMockConnectTransport(
      {},
      { onInstanceTypeCreate: () => create(InstanceTypesCreateResponseSchema, {}) },
    );
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useCreateInstanceType(), { wrapper });

    act(() => {
      result.current.mutate({
        metadata: { name: 'new-it' },
        spec: { cores: 4, memoryGib: 16 },
      });
    });

    await waitFor(() => expect(result.current.isSuccess || result.current.isError).toBe(true));
    expect(result.current.isError).toBe(true);
  });
});

describe('useUpdateInstanceType', () => {
  const mutateAndCaptureUpdate = async (
    input: Parameters<ReturnType<typeof useUpdateInstanceType>['mutate']>[0],
  ) => {
    let captured: Record<string, unknown> | undefined;
    const transport = createMockConnectTransport(
      { privateInstanceTypes: [makeInstanceType(input.id)] },
      {
        onInstanceTypeUpdate: (req) => {
          captured = req as unknown as Record<string, unknown>;
          return create(InstanceTypesUpdateResponseSchema, {
            object: makeInstanceType(input.id),
          });
        },
      },
    );
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useUpdateInstanceType(), { wrapper });

    act(() => {
      result.current.mutate(input);
    });

    await waitFor(() => expect(result.current.isSuccess || result.current.isError).toBe(true));
    expect(result.current.isSuccess).toBe(true);
    return captured;
  };

  it('sends the given body with a matching update mask', async () => {
    const captured = await mutateAndCaptureUpdate({
      id: 'it-1',
      body: { spec: { state: InstanceTypeState.DEPRECATED } },
    });

    expect((captured?.updateMask as { paths?: string[] } | undefined)?.paths).toEqual([
      'spec.state',
    ]);
    const object = captured?.object as { id?: string; spec?: { state?: InstanceTypeState } };
    expect(object.id).toBe('it-1');
    expect(object.spec?.state).toBe(InstanceTypeState.DEPRECATED);
  });

  it('sends a body targeting OBSOLETE', async () => {
    const captured = await mutateAndCaptureUpdate({
      id: 'it-1',
      body: { spec: { state: InstanceTypeState.OBSOLETE } },
    });

    const object = captured?.object as { spec?: { state?: InstanceTypeState } };
    expect(object.spec?.state).toBe(InstanceTypeState.OBSOLETE);
  });

  it('sends a body targeting ACTIVE', async () => {
    const captured = await mutateAndCaptureUpdate({
      id: 'it-1',
      body: { spec: { state: InstanceTypeState.ACTIVE } },
    });

    const object = captured?.object as { spec?: { state?: InstanceTypeState } };
    expect(object.spec?.state).toBe(InstanceTypeState.ACTIVE);
  });
});

describe('useDeleteInstanceType', () => {
  it('deletes an instance type by id', async () => {
    const transport = createMockConnectTransport({
      privateInstanceTypes: [makeInstanceType('it-1')],
    });
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useDeleteInstanceType(), { wrapper });

    act(() => {
      result.current.mutate('it-1');
    });

    await waitFor(() => expect(result.current.isSuccess || result.current.isError).toBe(true));
    expect(result.current.isSuccess).toBe(true);
  });
});

describe('invalidateInstanceTypesQueries', () => {
  const asApiQueryClient = (qc: QueryClient) =>
    qc as unknown as Parameters<typeof invalidateInstanceTypesQueries>[0];

  it('invalidates the private instance types list query', async () => {
    const qc = new QueryClient();
    qc.setQueryData(['v1/private/instance_types'], { items: [] });

    await invalidateInstanceTypesQueries(asApiQueryClient(qc));

    expect(qc.getQueryState(['v1/private/instance_types'])?.isInvalidated).toBe(true);
  });
});
