import type { ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { ConsoleResourceType, ConsoleType } from '@osac/types';

import { useCreateConsoleSession } from './console-session';

const createMock = vi.fn();

vi.mock('../api-context', () => ({
  useApiFetch: () => ({
    create: createMock,
  }),
}));

describe('useCreateConsoleSession', () => {
  beforeEach(() => {
    createMock.mockReset();
  });

  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>
  );

  it('calls ConsoleSessions.create with the session request shape', async () => {
    createMock.mockResolvedValue({
      object: {
        resourceType: ConsoleResourceType.COMPUTE_INSTANCE,
        resourceId: 'vm-1',
        type: ConsoleType.VNC,
        ticket: 'encrypted-ticket',
      },
    });

    const { result } = renderHook(() => useCreateConsoleSession(), { wrapper });
    result.current.mutate({
      resourceType: ConsoleResourceType.COMPUTE_INSTANCE,
      resourceId: 'vm-1',
      type: ConsoleType.VNC,
      clientId: '',
    });

    await waitFor(() => expect(result.current.isSuccess).toBe(true));

    expect(createMock).toHaveBeenCalledWith({
      object: {
        resourceType: ConsoleResourceType.COMPUTE_INSTANCE,
        resourceId: 'vm-1',
        type: ConsoleType.VNC,
        clientId: '',
      },
    });
    expect(result.current.data?.ticket).toBe('encrypted-ticket');
  });
});
