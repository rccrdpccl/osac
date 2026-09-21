import type { ReactNode } from 'react';
import { type Client, Code, ConnectError, createRouterTransport } from '@connectrpc/connect';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { renderHook, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  ComputeInstances,
  ExternalIPAttachment,
  ExternalIPAttachments,
  ExternalIPAttachmentsCreateRequest,
  ExternalIPState,
  ExternalIPs,
} from '@osac/types';

import {
  EXTERNAL_IP_ALLOCATION_POLL_MAX_ATTEMPTS,
  EXTERNAL_IP_ALLOCATION_POLL_MS,
  pollExternalIpUntilAllocated,
  useAttachExternalIp,
} from './external-ip';
import { ApiProvider } from '../api-context';

const externalIpWithState = (state: ExternalIPState, message?: string) => ({
  id: 'eip-1',
  status: { state, message },
});

const createMockExternalIpsClient = (
  getMock: ReturnType<typeof vi.fn>,
): Client<typeof ExternalIPs> =>
  ({
    get: getMock,
    create: vi.fn(),
    delete: vi.fn(),
    list: vi.fn(),
    update: vi.fn(),
  }) as unknown as Client<typeof ExternalIPs>;

describe('pollExternalIpUntilAllocated', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('resolves as soon as the ExternalIP reaches ALLOCATED', async () => {
    const getMock = vi.fn().mockResolvedValue({
      object: externalIpWithState(ExternalIPState.EXTERNAL_IP_STATE_ALLOCATED),
    });
    const client = createMockExternalIpsClient(getMock);

    const result = await pollExternalIpUntilAllocated(client, 'eip-1');

    expect(result.status?.state).toBe(ExternalIPState.EXTERNAL_IP_STATE_ALLOCATED);
    expect(getMock).toHaveBeenCalledTimes(1);
    expect(getMock).toHaveBeenCalledWith({ id: 'eip-1' });
  });

  it('keeps polling through PENDING until ALLOCATED', async () => {
    const getMock = vi
      .fn()
      .mockResolvedValueOnce({
        object: externalIpWithState(ExternalIPState.EXTERNAL_IP_STATE_PENDING),
      })
      .mockResolvedValueOnce({
        object: externalIpWithState(ExternalIPState.EXTERNAL_IP_STATE_PENDING),
      })
      .mockResolvedValueOnce({
        object: externalIpWithState(ExternalIPState.EXTERNAL_IP_STATE_ALLOCATED),
      });
    const client = createMockExternalIpsClient(getMock);

    const resultPromise = pollExternalIpUntilAllocated(client, 'eip-1');
    await vi.advanceTimersByTimeAsync(EXTERNAL_IP_ALLOCATION_POLL_MS * 2);
    const result = await resultPromise;

    expect(result.status?.state).toBe(ExternalIPState.EXTERNAL_IP_STATE_ALLOCATED);
    expect(getMock).toHaveBeenCalledTimes(3);
  });

  it('throws with the status message when the ExternalIP reaches FAILED', async () => {
    const getMock = vi.fn().mockResolvedValue({
      object: externalIpWithState(
        ExternalIPState.EXTERNAL_IP_STATE_FAILED,
        'no external IP addresses available',
      ),
    });
    const client = createMockExternalIpsClient(getMock);

    await expect(pollExternalIpUntilAllocated(client, 'eip-1')).rejects.toThrow(
      'no external IP addresses available',
    );
  });

  it('propagates a client rejection without retrying', async () => {
    const getMock = vi.fn().mockRejectedValue(new Error('network error'));
    const client = createMockExternalIpsClient(getMock);

    await expect(pollExternalIpUntilAllocated(client, 'eip-1')).rejects.toThrow('network error');
    expect(getMock).toHaveBeenCalledTimes(1);
  });

  it('throws a timeout error after exhausting all poll attempts', async () => {
    const getMock = vi.fn().mockResolvedValue({
      object: externalIpWithState(ExternalIPState.EXTERNAL_IP_STATE_PENDING),
    });
    const client = createMockExternalIpsClient(getMock);

    const resultPromise = pollExternalIpUntilAllocated(client, 'eip-1');
    const assertion = expect(resultPromise).rejects.toThrow(
      'Timed out waiting for the external IP to be allocated',
    );
    await vi.advanceTimersByTimeAsync(
      EXTERNAL_IP_ALLOCATION_POLL_MS * EXTERNAL_IP_ALLOCATION_POLL_MAX_ATTEMPTS,
    );
    await assertion;
    expect(getMock).toHaveBeenCalledTimes(EXTERNAL_IP_ALLOCATION_POLL_MAX_ATTEMPTS);
  });
});

const createAttachExternalIpTransport = ({
  onExternalIpDelete,
  onAttachmentCreate,
}: {
  onExternalIpDelete?: (req: { id: string }) => void;
  onAttachmentCreate?: (req: ExternalIPAttachmentsCreateRequest) => ExternalIPAttachment;
} = {}) =>
  createRouterTransport((router) => {
    router.service(ExternalIPs, {
      create: () => ({ object: externalIpWithState(ExternalIPState.EXTERNAL_IP_STATE_PENDING) }),
      get: () => ({ object: externalIpWithState(ExternalIPState.EXTERNAL_IP_STATE_ALLOCATED) }),
      delete: (req) => {
        onExternalIpDelete?.(req);
        return {};
      },
    });

    router.service(ExternalIPAttachments, {
      create: (req) => {
        if (onAttachmentCreate) {
          return { object: onAttachmentCreate(req) };
        }
        return {
          object: {
            id: 'attachment-1',
            spec: {
              externalIp: { id: 'eip-1' },
              target: req.object?.spec?.target,
            },
          },
        };
      },
    });

    router.service(ComputeInstances, {
      list: () => ({ items: [] }),
    });
  });

const renderUseAttachExternalIp = (
  transport: ReturnType<typeof createAttachExternalIpTransport>,
) => {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  const wrapper = ({ children }: { children: ReactNode }) => (
    <ApiProvider transport={transport}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </ApiProvider>
  );
  return renderHook(() => useAttachExternalIp(), { wrapper });
};

describe('useAttachExternalIp', () => {
  it('creates the ExternalIP, polls until allocated, then attaches it to the ComputeInstance', async () => {
    const transport = createAttachExternalIpTransport();

    const { result } = renderUseAttachExternalIp(transport);
    result.current.mutate({ computeInstanceId: 'vm-1', pool: 'pool-1' });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(result.current.data?.spec?.externalIp?.id).toBe('eip-1');
  });

  it('rolls back the allocated ExternalIP when creating the attachment fails', async () => {
    const deletedIds: string[] = [];
    const transport = createAttachExternalIpTransport({
      onExternalIpDelete: (req) => {
        deletedIds.push(req.id);
      },
      onAttachmentCreate: () => {
        throw new ConnectError(
          'an ExternalIPAttachment already exists for ComputeInstance',
          Code.AlreadyExists,
        );
      },
    });

    const { result } = renderUseAttachExternalIp(transport);
    result.current.mutate({ computeInstanceId: 'vm-1', pool: 'pool-1' });

    await waitFor(() => expect(result.current.isError).toBe(true));

    expect(getErrorMessageFromResult(result.current.error)).toContain(
      'an ExternalIPAttachment already exists',
    );
    expect(deletedIds).toEqual(['eip-1']);
  });
});

const getErrorMessageFromResult = (error: unknown): string => {
  if (error instanceof ConnectError) {
    return error.rawMessage;
  }
  return error instanceof Error ? error.message : String(error);
};
