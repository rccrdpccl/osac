import { act, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const disconnect = vi.fn();
const focus = vi.fn();

class RFB {
  scaleViewport = false;

  background = '';

  disconnect = disconnect;

  focus = focus;

  listeners: Record<string, Array<() => void>> = {};

  // vi.fn(RFB) does not preserve the prototype chain, so listener methods must be
  // own-property arrow fields rather than RFB.prototype methods.
  addEventListener = (type: string, listener: () => void) => {
    (this.listeners[type] ??= []).push(listener);
  };

  removeEventListener = (type: string, listener: () => void) => {
    this.listeners[type] = (this.listeners[type] ?? []).filter((l) => l !== listener);
  };

  emit = (type: string) => {
    this.listeners[type]?.forEach((listener) => listener());
  };
}

const RFBMock = vi.fn(RFB);

vi.mock('./novnc-rfb', () => ({
  loadVncRfbConstructor: vi.fn(() => Promise.resolve(RFBMock)),
}));

const {
  default: VncConsoleViewer,
  RFB_CONNECT_TIMEOUT_MS,
  RFB_INIT_TIMEOUT_MS,
} = await import('./VncConsoleViewer');

describe('VncConsoleViewer', () => {
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

  it('renders the VNC container when a WebSocket is provided', async () => {
    const webSocket = { close: vi.fn() } as unknown as WebSocket;

    render(<VncConsoleViewer webSocket={webSocket} />);

    expect(screen.getByTestId('vnc-console-viewer')).toBeInTheDocument();
    await waitFor(() => expect(RFBMock).toHaveBeenCalled());
  });

  it('applies the viewport class that gives the container a real height', () => {
    render(<VncConsoleViewer webSocket={{ close: vi.fn() } as unknown as WebSocket} />);

    expect(screen.getByTestId('vnc-console-viewer')).toHaveClass('vm-console-viewport');
  });

  it('disconnects the RFB session on unmount', async () => {
    const webSocket = { close: vi.fn() } as unknown as WebSocket;

    const { unmount } = render(<VncConsoleViewer webSocket={webSocket} />);
    await waitFor(() => expect(RFBMock).toHaveBeenCalled());
    unmount();

    expect(disconnect).toHaveBeenCalled();
  });

  it('calls onConnected when the RFB reports its own connect event', async () => {
    const onConnected = vi.fn();
    const webSocket = { close: vi.fn() } as unknown as WebSocket;

    render(<VncConsoleViewer onConnected={onConnected} webSocket={webSocket} />);
    await waitFor(() => expect(RFBMock).toHaveBeenCalled());

    const rfbInstance = RFBMock.mock.results[0].value as RFB;
    act(() => {
      rfbInstance.emit('connect');
    });

    expect(onConnected).toHaveBeenCalled();
    expect(focus).toHaveBeenCalled();
  });

  it('exposes focus on the imperative handle', async () => {
    const webSocket = { close: vi.fn() } as unknown as WebSocket;
    const ref = {
      current: null as null | { focus: () => void; pasteFromClipboard: () => Promise<void> },
    };

    render(<VncConsoleViewer ref={ref} webSocket={webSocket} />);
    await waitFor(() => expect(RFBMock).toHaveBeenCalled());

    act(() => {
      ref.current?.focus();
    });

    expect(focus).toHaveBeenCalled();
  });

  it('reports noVNC load failures', async () => {
    const onError = vi.fn();
    const { loadVncRfbConstructor } = await import('./novnc-rfb');
    vi.mocked(loadVncRfbConstructor).mockRejectedValueOnce(new Error('noVNC import failed'));

    render(
      <VncConsoleViewer onError={onError} webSocket={{ close: vi.fn() } as unknown as WebSocket} />,
    );

    await waitFor(() => expect(onError).toHaveBeenCalledWith('noVNC import failed'));
  });

  it('reports an error when the viewport never gets a size', async () => {
    vi.useFakeTimers();
    Object.defineProperty(HTMLElement.prototype, 'clientWidth', {
      configurable: true,
      get: () => 0,
    });
    Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
      configurable: true,
      get: () => 0,
    });
    const onError = vi.fn();

    render(
      <VncConsoleViewer onError={onError} webSocket={{ close: vi.fn() } as unknown as WebSocket} />,
    );

    await act(async () => {
      await vi.advanceTimersByTimeAsync(RFB_INIT_TIMEOUT_MS);
    });

    expect(RFBMock).not.toHaveBeenCalled();
    expect(onError).toHaveBeenCalledWith(
      'Graphical console viewer could not start because the display area has no size',
    );
  });

  it('reports an error when RFB never fires connect', async () => {
    vi.useFakeTimers();
    const onError = vi.fn();

    render(
      <VncConsoleViewer onError={onError} webSocket={{ close: vi.fn() } as unknown as WebSocket} />,
    );

    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(RFBMock).toHaveBeenCalled();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(RFB_CONNECT_TIMEOUT_MS);
    });

    expect(onError).toHaveBeenCalledWith(
      'Timed out waiting for the graphical console to finish connecting',
    );
  });

  it('reports an error when RFB disconnects before connect', async () => {
    const onError = vi.fn();

    render(
      <VncConsoleViewer onError={onError} webSocket={{ close: vi.fn() } as unknown as WebSocket} />,
    );
    await waitFor(() => expect(RFBMock).toHaveBeenCalled());

    const rfbInstance = RFBMock.mock.results[0].value as RFB;
    act(() => {
      rfbInstance.emit('disconnect');
    });

    expect(onError).toHaveBeenCalledWith(
      'Graphical console disconnected before it finished connecting',
    );
  });

  it('reports a plain disconnected message when RFB disconnects after connecting', async () => {
    const onError = vi.fn();

    render(
      <VncConsoleViewer onError={onError} webSocket={{ close: vi.fn() } as unknown as WebSocket} />,
    );
    await waitFor(() => expect(RFBMock).toHaveBeenCalled());

    const rfbInstance = RFBMock.mock.results[0].value as RFB;
    act(() => {
      rfbInstance.emit('connect');
    });
    act(() => {
      rfbInstance.emit('disconnect');
    });

    expect(onError).toHaveBeenCalledWith('Graphical console disconnected');
  });

  it('keeps the RFB session alive across a re-render with new onConnected/onError references', async () => {
    const webSocket = { close: vi.fn() } as unknown as WebSocket;

    const { rerender } = render(
      <VncConsoleViewer onConnected={() => {}} onError={() => {}} webSocket={webSocket} />,
    );
    await waitFor(() => expect(RFBMock).toHaveBeenCalledTimes(1));

    rerender(<VncConsoleViewer onConnected={() => {}} onError={() => {}} webSocket={webSocket} />);

    expect(RFBMock).toHaveBeenCalledTimes(1);
    expect(disconnect).not.toHaveBeenCalled();
  });
});
