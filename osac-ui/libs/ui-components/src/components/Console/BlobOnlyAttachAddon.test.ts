import type { Terminal } from '@xterm/xterm';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import { BlobOnlyAttachAddon } from './BlobOnlyAttachAddon';

const createFakeSocket = () => {
  const messageListeners: Array<(event: MessageEvent) => void> = [];
  return {
    binaryType: 'blob' as BinaryType,
    readyState: WebSocket.OPEN as number,
    send: vi.fn(),
    addEventListener: vi.fn((event: string, listener: (event: MessageEvent) => void) => {
      if (event === 'message') {
        messageListeners.push(listener);
      }
    }),
    removeEventListener: vi.fn((event: string, listener: (event: MessageEvent) => void) => {
      if (event === 'message') {
        const index = messageListeners.indexOf(listener);
        if (index >= 0) {
          messageListeners.splice(index, 1);
        }
      }
    }),
    emitMessage: (data: unknown) => {
      messageListeners.forEach((listener) => listener({ data } as MessageEvent));
    },
    get messageListenerCount() {
      return messageListeners.length;
    },
  };
};

// jsdom's Blob does not implement arrayBuffer(); real browsers do, and the addon
// relies on it. Build a real Blob (so `instanceof Blob` still holds) and back-fill
// arrayBuffer() when the environment lacks it.
const makeBlob = (values: number[]) => {
  const buffer = new Uint8Array(values).buffer;
  const blob = new Blob([buffer]);
  if (typeof blob.arrayBuffer !== 'function') {
    Object.defineProperty(blob, 'arrayBuffer', {
      value: () => Promise.resolve(buffer),
    });
  }
  return blob;
};

const createFakeTerminal = () => {
  const dataDisposable = { dispose: vi.fn() };
  let dataListener: ((data: string) => void) | undefined;
  return {
    write: vi.fn(),
    onData: vi.fn((listener: (data: string) => void) => {
      dataListener = listener;
      return dataDisposable;
    }),
    emitData: (data: string) => dataListener?.(data),
    dataDisposable,
  };
};

describe('BlobOnlyAttachAddon', () => {
  let socket: ReturnType<typeof createFakeSocket>;
  let terminal: ReturnType<typeof createFakeTerminal>;
  let addon: BlobOnlyAttachAddon;

  beforeEach(() => {
    socket = createFakeSocket();
    terminal = createFakeTerminal();
    addon = new BlobOnlyAttachAddon(socket as unknown as WebSocket);
    addon.activate(terminal as unknown as Terminal);
  });

  it('sets the socket to binary and subscribes to messages on activate', () => {
    expect(socket.binaryType).toBe('arraybuffer');
    expect(socket.messageListenerCount).toBe(1);
  });

  it('writes string frames straight to the terminal', async () => {
    socket.emitMessage('hello');

    await vi.waitFor(() => expect(terminal.write).toHaveBeenCalledWith('hello'));
  });

  it('writes ArrayBuffer frames as a Uint8Array', async () => {
    const bytes = new Uint8Array([104, 105]);
    socket.emitMessage(bytes.buffer);

    await vi.waitFor(() => expect(terminal.write).toHaveBeenCalledWith(new Uint8Array([104, 105])));
  });

  it('writes Blob frames as a Uint8Array', async () => {
    socket.emitMessage(makeBlob([120, 121]));

    await vi.waitFor(() => expect(terminal.write).toHaveBeenCalledWith(new Uint8Array([120, 121])));
  });

  it('preserves arrival order even when a Blob resolves after a later frame', async () => {
    socket.emitMessage(makeBlob([49])); // '1', async conversion
    socket.emitMessage('2'); // string, synchronous

    await vi.waitFor(() => expect(terminal.write).toHaveBeenCalledTimes(2));
    expect(terminal.write.mock.calls[0][0]).toEqual(new Uint8Array([49]));
    expect(terminal.write.mock.calls[1][0]).toBe('2');
  });

  it('forwards terminal input to the socket as a binary frame only while it is open', () => {
    terminal.emitData('a');
    expect(socket.send).toHaveBeenCalledWith(new TextEncoder().encode('a'));

    socket.send.mockClear();
    socket.readyState = WebSocket.CLOSING;
    terminal.emitData('b');
    expect(socket.send).not.toHaveBeenCalled();
  });

  it('removes its listeners on dispose', () => {
    addon.dispose();

    expect(socket.messageListenerCount).toBe(0);
    expect(terminal.dataDisposable.dispose).toHaveBeenCalled();
  });
});
