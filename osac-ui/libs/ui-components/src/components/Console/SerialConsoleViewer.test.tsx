import { act, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const focus = vi.fn();
const dispose = vi.fn();
const open = vi.fn();
const loadAddon = vi.fn();
const paste = vi.fn();
const fit = vi.fn();

class TerminalMock {
  focus = focus;
  dispose = dispose;
  open = open;
  loadAddon = loadAddon;
  paste = paste;
}

class FitAddonMock {
  fit = fit;
}

vi.mock('./xterm-loader', () => ({
  loadXtermConstructors: vi.fn(() =>
    Promise.resolve({ Terminal: TerminalMock, FitAddon: FitAddonMock }),
  ),
}));

const createOpenSocket = () =>
  ({
    readyState: WebSocket.OPEN,
    binaryType: 'blob' as BinaryType,
    close: vi.fn(),
    send: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  }) as unknown as WebSocket;

const { default: SerialConsoleViewer } = await import('./SerialConsoleViewer');

describe('SerialConsoleViewer', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', {
      configurable: true,
      get: () => 1024,
    });
    Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
      configurable: true,
      get: () => 768,
    });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('renders the serial container with the shared viewport class', () => {
    render(<SerialConsoleViewer webSocket={createOpenSocket()} />);

    const container = screen.getByTestId('serial-console-viewer');
    expect(container).toBeInTheDocument();
    expect(container).toHaveClass('vm-console-viewport');
  });

  it('opens a terminal against the container and attaches to the socket', async () => {
    render(<SerialConsoleViewer webSocket={createOpenSocket()} />);

    await waitFor(() => expect(open).toHaveBeenCalled());
    // FitAddon plus the socket attach addon are both loaded.
    expect(loadAddon).toHaveBeenCalledTimes(2);
  });

  it('calls onConnected once the terminal is attached to an open socket', async () => {
    const onConnected = vi.fn();

    render(<SerialConsoleViewer onConnected={onConnected} webSocket={createOpenSocket()} />);

    await waitFor(() => expect(onConnected).toHaveBeenCalled());
    expect(focus).toHaveBeenCalled();
  });

  it('waits for the socket to open before reporting connected', async () => {
    const listeners: Record<string, (event?: Event) => void> = {};
    const socket = {
      readyState: WebSocket.CONNECTING,
      binaryType: 'blob' as BinaryType,
      close: vi.fn(),
      send: vi.fn(),
      addEventListener: vi.fn((event: string, listener: (event?: Event) => void) => {
        listeners[event] = listener;
      }),
      removeEventListener: vi.fn(),
    } as unknown as WebSocket;
    const onConnected = vi.fn();

    render(<SerialConsoleViewer onConnected={onConnected} webSocket={socket} />);
    await waitFor(() => expect(open).toHaveBeenCalled());
    expect(onConnected).not.toHaveBeenCalled();

    act(() => {
      listeners.open?.();
    });

    expect(onConnected).toHaveBeenCalled();
  });

  it('exposes focus on the imperative handle', async () => {
    const ref = {
      current: null as null | { focus: () => void; pasteFromClipboard: () => Promise<void> },
    };

    render(<SerialConsoleViewer ref={ref} webSocket={createOpenSocket()} />);
    await waitFor(() => expect(open).toHaveBeenCalled());

    act(() => {
      ref.current?.focus();
    });

    expect(focus).toHaveBeenCalled();
  });

  it('disposes the terminal on unmount', async () => {
    const { unmount } = render(<SerialConsoleViewer webSocket={createOpenSocket()} />);
    await waitFor(() => expect(open).toHaveBeenCalled());

    unmount();

    expect(dispose).toHaveBeenCalled();
  });

  it('reports xterm load failures through onError', async () => {
    const onError = vi.fn();
    const { loadXtermConstructors } = await import('./xterm-loader');
    vi.mocked(loadXtermConstructors).mockRejectedValueOnce(new Error('xterm import failed'));

    render(<SerialConsoleViewer onError={onError} webSocket={createOpenSocket()} />);

    await waitFor(() => expect(onError).toHaveBeenCalledWith('xterm import failed'));
  });
});
