import React, { type ReactNode, createElement } from 'react';
import { create } from '@bufbuild/protobuf';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { renderHook, waitFor } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { type ClusterVersion, ClusterVersionSchema, ClusterVersionState } from '@osac/types';

import {
  CLUSTER_VERSION_ACTIVE_LIST_FILTER,
  CLUSTER_VERSION_ALL_STATES_LIST_FILTER,
  clusterVersionNamesFilter,
  useClusterVersion,
  useClusterVersions,
} from './cluster-versions';
import { createMockConnectTransport } from '../../test-utils/createMockConnectTransport';
import { ApiProvider } from '../api-context';

const makeClusterVersion = (
  id: string,
  state: ClusterVersionState = ClusterVersionState.ACTIVE,
  enabled = true,
): ClusterVersion =>
  create(ClusterVersionSchema, {
    id,
    metadata: { name: id },
    spec: { version: id.replace(/-/g, '.'), state, enabled },
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

describe('cluster version list filters', () => {
  it('restricts the active filter to ACTIVE/DEPRECATED enabled versions', () => {
    expect(CLUSTER_VERSION_ACTIVE_LIST_FILTER).toBe(
      `(this.spec.state == ${ClusterVersionState.ACTIVE} || this.spec.state == ${ClusterVersionState.DEPRECATED}) && this.spec.enabled == true`,
    );
  });

  it('references spec.state and spec.enabled so the all-states filter returns every state', () => {
    // Both fields must be referenced to defeat the public List RPC's default
    // hiding of obsolete/disabled versions (see cluster_versions_server.go).
    expect(CLUSTER_VERSION_ALL_STATES_LIST_FILTER).toContain('this.spec.state');
    expect(CLUSTER_VERSION_ALL_STATES_LIST_FILTER).toContain('this.spec.enabled');
    expect(CLUSTER_VERSION_ALL_STATES_LIST_FILTER).toContain(`${ClusterVersionState.OBSOLETE}`);
  });

  it('compares the enum spec.state with == and never list membership', () => {
    // The backend filter translator only resolves enum int literals to their stored
    // string name for ==/!=; `state in [...]` produces a text-vs-int SQL clause that
    // Postgres rejects with "failed to list". Guard against reintroducing it.
    expect(CLUSTER_VERSION_ALL_STATES_LIST_FILTER).toContain(
      `this.spec.state == ${ClusterVersionState.OBSOLETE}`,
    );
    expect(CLUSTER_VERSION_ALL_STATES_LIST_FILTER).not.toContain('this.spec.state in');
  });

  it('scopes the name filter to the given versions while keeping all-states predicates', () => {
    const filter = clusterVersionNamesFilter(['v4.17', 'v4.15']);

    // metadata.name is a string field, so `in [...]` is safe (unlike enum spec.state).
    expect(filter).toContain('this.metadata.name in ["v4.17", "v4.15"]');
    // All-states predicates remain so obsolete/disabled versions still resolve.
    expect(filter).toContain('this.spec.state');
    expect(filter).toContain('this.spec.enabled');
    expect(filter).toContain(`this.spec.state == ${ClusterVersionState.OBSOLETE}`);
    expect(filter).not.toContain('this.spec.state in');
  });
});

describe('useClusterVersions', () => {
  it('unwraps the list response into items', async () => {
    const transport = createMockConnectTransport({
      clusterVersions: [makeClusterVersion('4-17-0'), makeClusterVersion('4-16-0')],
    });
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useClusterVersions(), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.map((item) => item.id)).toEqual(['4-17-0', '4-16-0']);
  });

  it('passes the filter through to the list request', async () => {
    let capturedFilter: string | undefined;
    const transport = createMockConnectTransport(
      {},
      {
        onClusterVersionList: (req) => {
          capturedFilter = req.filter;
          return { items: [] };
        },
      },
    );
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(
      () => useClusterVersions({ filter: CLUSTER_VERSION_ACTIVE_LIST_FILTER }),
      { wrapper },
    );

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(capturedFilter).toBe(CLUSTER_VERSION_ACTIVE_LIST_FILTER);
  });
});

describe('useClusterVersion', () => {
  it('fetches a single version by id', async () => {
    const transport = createMockConnectTransport({
      clusterVersions: [makeClusterVersion('4-17-0')],
    });
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useClusterVersion('4-17-0'), { wrapper });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));
    expect(result.current.data?.id).toBe('4-17-0');
  });

  it('is disabled when the id is falsy', () => {
    const transport = createMockConnectTransport({
      clusterVersions: [makeClusterVersion('4-17-0')],
    });
    const { wrapper } = makeWrapper(transport);
    const { result } = renderHook(() => useClusterVersion(undefined), { wrapper });

    expect(result.current.fetchStatus).toBe('idle');
    expect(result.current.data).toBeUndefined();
  });
});
