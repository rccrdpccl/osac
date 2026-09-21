import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { ConsoleResourceType, ConsoleType } from '@osac/types';

import { type UseConsoleSessionParams, useConsoleSession } from './useConsoleSession';

const mutateAsync = vi.fn();

vi.mock('../../api/v1/console-session', () => ({
  useCreateConsoleSession: () => ({
    mutateAsync,
    isPending: false,
  }),
}));

vi.mock('./console-websocket', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./console-websocket')>();
  return {
    ...actual,
    clearConsoleTicketCookie: vi.fn(),
    openConsoleWebSocket: vi.fn(),
  };
});

const { clearConsoleTicketCookie, openConsoleWebSocket } = await import('./console-websocket');

const createMockWebSocket = ({ autoOpen = true }: { autoOpen?: boolean } = {}) => {
  const listeners = new Map<string, Array<(event?: CloseEvent) => void>>();

  return {
    close: vi.fn(),
    addEventListener: vi.fn((event: string, listener: (event?: CloseEvent) => void) => {
      const handlers = listeners.get(event) ?? [];
      handlers.push(listener);
      listeners.set(event, handlers);

      if (event === 'open' && autoOpen) {
        queueMicrotask(listener);
      }
    }),
    dispatchEvent: (event: string, payload?: CloseEvent) => {
      listeners.get(event)?.forEach((listener) => listener(payload));
    },
  };
};

const runningParams: UseConsoleSessionParams = {
  resourceType: ConsoleResourceType.COMPUTE_INSTANCE,
  resourceId: 'vm-1',
  isRunning: true,
  consoleType: ConsoleType.VNC,
};

const stoppedParams: UseConsoleSessionParams = {
  ...runningParams,
  isRunning: false,
};

// Stubs navigator.locks without replacing the rest of navigator (userEvent etc. in
// sibling test files rely on it staying intact). A steal request always grants the
// lock (matching the real Web Locks API); a plain ifAvailable request grants it only
// when `grants` is true, modeling whether another tab already holds it.
const stubConsoleClientLock = ({ grants = true }: { grants?: boolean } = {}) => {
  const requestMock = vi.fn(
    (_name: string, options: LockOptions, callback: (lock: Lock | null) => Promise<unknown>) =>
      callback(options.steal || grants ? ({} as Lock) : null),
  );
  Object.defineProperty(navigator, 'locks', {
    value: { request: requestMock },
    configurable: true,
  });
  return requestMock;
};

describe('useConsoleSession', () => {
  beforeEach(() => {
    mutateAsync.mockReset();
    vi.mocked(clearConsoleTicketCookie).mockReset();
    vi.mocked(openConsoleWebSocket).mockReset();
    stubConsoleClientLock();
    localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    Reflect.deleteProperty(navigator, 'locks');
  });

  it('connect() creates a ticket and opens the WebSocket', async () => {
    const webSocket = createMockWebSocket();
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(webSocket as unknown as WebSocket);

    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });

    await waitFor(() => expect(result.current.connectionState).toBe('connected'));
    expect(mutateAsync).toHaveBeenCalled();
    expect(openConsoleWebSocket).toHaveBeenCalled();
  });

  it('does nothing when connect() is called while isRunning is false', () => {
    const { result } = renderHook(() => useConsoleSession(stoppedParams));

    act(() => {
      result.current.connect();
    });

    expect(mutateAsync).not.toHaveBeenCalled();
    expect(result.current.connectionState).toBe('idle');
  });

  it('disconnects when isRunning flips to false, and connect() can reconnect once it flips back', async () => {
    const firstSocket = createMockWebSocket();
    const secondSocket = createMockWebSocket();
    mutateAsync
      .mockResolvedValueOnce({ ticket: 'ticket-1' })
      .mockResolvedValueOnce({ ticket: 'ticket-2' });
    vi.mocked(openConsoleWebSocket)
      .mockReturnValueOnce(firstSocket as unknown as WebSocket)
      .mockReturnValueOnce(secondSocket as unknown as WebSocket);

    const { result, rerender } = renderHook(
      ({ params }: { params: UseConsoleSessionParams }) => useConsoleSession(params),
      { initialProps: { params: runningParams } },
    );

    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('connected'));

    rerender({ params: stoppedParams });

    expect(firstSocket.close).toHaveBeenCalled();
    expect(clearConsoleTicketCookie).toHaveBeenCalled();

    rerender({ params: runningParams });
    act(() => {
      result.current.connect();
    });

    await waitFor(() => expect(result.current.connectionState).toBe('connected'));

    expect(mutateAsync).toHaveBeenCalledTimes(2);
    expect(openConsoleWebSocket).toHaveBeenCalledTimes(2);
    expect(result.current.webSocket).toBe(secondSocket);
  });

  it('cleans up the WebSocket on unmount', async () => {
    const webSocket = createMockWebSocket();
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(webSocket as unknown as WebSocket);

    const { result, unmount } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('connected'));

    unmount();

    expect(webSocket.close).toHaveBeenCalled();
    expect(clearConsoleTicketCookie).toHaveBeenCalled();
  });

  it('surfaces ticket creation errors', async () => {
    mutateAsync.mockRejectedValue(new Error('insufficient permissions'));

    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });

    await waitFor(() => expect(result.current.connectionState).toBe('error'));
    expect(result.current.errorMessage).toBe('insufficient permissions');
    expect(result.current.errorKind).toBe('generic');
    expect(openConsoleWebSocket).not.toHaveBeenCalled();
  });

  it('surfaces a possible-conflict message when closed while still connecting', async () => {
    // The browser hides the real reason a WS handshake was rejected (see
    // useConsoleSession.ts's POSSIBLE_CONFLICT_MESSAGE comment), so every such failure
    // gets the same message regardless of close code. No action is offered here: takeOver
    // would resend the identical request an automatic connect already sent, so it cannot
    // do anything a retry wouldn't (see ConsoleErrorKind's doc comment).
    const webSocket = createMockWebSocket({ autoOpen: false });
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(webSocket as unknown as WebSocket);

    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('connecting'));

    act(() => {
      webSocket.dispatchEvent('close', { code: 1002, reason: '' } as CloseEvent);
    });

    await waitFor(() => expect(result.current.connectionState).toBe('error'));
    expect(result.current.errorMessage).toBe(
      'This might be because the console is already open in another session.',
    );
    expect(result.current.errorKind).toBe('possibleConflict');
  });

  it("surfaces a sibling-tab-specific message without attempting to connect when this resource's lock is already held", async () => {
    // Unlike the generic case, we *know* a live sibling tab in this browser has this
    // exact resource's console open (the lock is only free when its holder is genuinely
    // gone), so this skips the doomed connect attempt entirely and shows a confident,
    // specific message pointing at "Take over".
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    stubConsoleClientLock({ grants: false });

    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });

    await waitFor(() => expect(result.current.connectionState).toBe('error'));
    expect(result.current.errorMessage).toBe(
      'This console is already open in another tab in this browser. Take over to continue here, or switch to that tab.',
    );
    expect(result.current.errorKind).toBe('siblingTabConflict');
    expect(mutateAsync).not.toHaveBeenCalled();
    expect(openConsoleWebSocket).not.toHaveBeenCalled();
  });

  it('surfaces unexpected WebSocket close errors', async () => {
    const webSocket = createMockWebSocket();
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(webSocket as unknown as WebSocket);

    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('connected'));

    act(() => {
      webSocket.dispatchEvent('close', { code: 1006, reason: '' } as CloseEvent);
    });

    await waitFor(() => expect(result.current.connectionState).toBe('error'));
    expect(result.current.errorMessage).toBe('Console connection was closed unexpectedly');
    // An established connection dropping isn't grounds to suspect another session — no
    // reason to offer takeOver here.
    expect(result.current.errorKind).toBe('generic');
  });

  it('reports viewer load failures', () => {
    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.reportViewerError('Failed to load graphical console viewer');
    });

    expect(result.current.connectionState).toBe('error');
    expect(result.current.errorMessage).toBe('Failed to load graphical console viewer');
    // The session itself is fine — only the viewer failed — so "Take over" (which
    // evicts a session) is not a relevant recovery action for this error.
    expect(result.current.errorKind).toBe('viewer');
  });

  it('tears down the socket and ticket cookie when the viewer fails after connecting', async () => {
    const webSocket = createMockWebSocket();
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(webSocket as unknown as WebSocket);

    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('connected'));

    act(() => {
      result.current.reportViewerError('noVNC protocol error');
    });

    // Otherwise the socket and Web Lock would stay alive despite the UI reporting a
    // failed console, leaving a stale server-side session that causes spurious
    // sibling-tab conflicts on retry.
    expect(webSocket.close).toHaveBeenCalled();
    expect(clearConsoleTicketCookie).toHaveBeenCalled();
    expect(result.current.webSocket).toBeNull();
    expect(result.current.connectionState).toBe('error');
    expect(result.current.errorMessage).toBe('noVNC protocol error');
    expect(result.current.errorKind).toBe('viewer');

    // socket.close() is async in a real browser: the 'close' listener registered by
    // connect() is still attached and fires later. Without invalidating the session
    // first, that listener's own cleanup would overwrite the viewer error above with
    // its generic close message.
    act(() => {
      webSocket.dispatchEvent('close', { code: 1000, reason: '' } as CloseEvent);
    });

    expect(result.current.errorMessage).toBe('noVNC protocol error');
    expect(result.current.errorKind).toBe('viewer');
  });

  it("sends this browser's shared client id when no other tab holds the lock", async () => {
    const webSocket = createMockWebSocket();
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(webSocket as unknown as WebSocket);
    const requestMock = stubConsoleClientLock({ grants: true });

    const { result } = renderHook(() => useConsoleSession(runningParams));

    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('connected'));

    const clientId = localStorage.getItem('osac-console-client-id');
    expect(clientId).toBeTruthy();
    expect(mutateAsync).toHaveBeenCalledWith({
      resourceType: ConsoleResourceType.COMPUTE_INSTANCE,
      resourceId: 'vm-1',
      clientId,
      type: ConsoleType.VNC,
    });
    // Locked per resource, not just per browser, so a sibling tab on a different
    // resource never blocks this one.
    expect(requestMock).toHaveBeenCalledWith(
      `${clientId}:${ConsoleResourceType.COMPUTE_INSTANCE}:vm-1`,
      { ifAvailable: true },
      expect.any(Function),
    );
  });

  it('mints the ticket for the requested console type', async () => {
    const webSocket = createMockWebSocket();
    mutateAsync.mockResolvedValue({ ticket: 'ticket-value' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(webSocket as unknown as WebSocket);

    const { result } = renderHook(() =>
      useConsoleSession({ ...runningParams, consoleType: ConsoleType.SERIAL }),
    );

    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('connected'));

    const clientId = localStorage.getItem('osac-console-client-id');
    expect(mutateAsync).toHaveBeenCalledWith({
      resourceType: ConsoleResourceType.COMPUTE_INSTANCE,
      resourceId: 'vm-1',
      clientId,
      type: ConsoleType.SERIAL,
    });
  });

  it('takeOver() steals the lock and reconnects with the shared client id', async () => {
    const socket = createMockWebSocket();
    mutateAsync.mockResolvedValue({ ticket: 'ticket-1' });
    vi.mocked(openConsoleWebSocket).mockReturnValue(socket as unknown as WebSocket);
    const requestMock = stubConsoleClientLock({ grants: false });

    const { result } = renderHook(() => useConsoleSession(runningParams));

    // The plain connect finds the lock already held by a sibling tab, so it skips
    // connecting entirely and surfaces the sibling-tab conflict error instead.
    act(() => {
      result.current.connect();
    });
    await waitFor(() => expect(result.current.connectionState).toBe('error'));
    expect(mutateAsync).not.toHaveBeenCalled();

    act(() => {
      result.current.takeOver();
    });

    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1));
    expect(requestMock).toHaveBeenLastCalledWith(
      expect.any(String),
      { steal: true },
      expect.any(Function),
    );
    await waitFor(() => expect(result.current.connectionState).toBe('connected'));
    expect(result.current.webSocket).toBe(socket);

    const clientId = localStorage.getItem('osac-console-client-id');
    expect(mutateAsync).toHaveBeenLastCalledWith({
      resourceType: ConsoleResourceType.COMPUTE_INSTANCE,
      resourceId: 'vm-1',
      clientId,
      type: ConsoleType.VNC,
    });
  });
});
