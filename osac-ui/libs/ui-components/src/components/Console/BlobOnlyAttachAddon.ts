import type { ITerminalAddon, Terminal } from '@xterm/xterm';

const writeSocketData = async (terminal: Terminal, data: Blob | ArrayBuffer | string) => {
  if (typeof data === 'string') {
    terminal.write(data);
    return;
  }

  if (data instanceof Blob) {
    terminal.write(new Uint8Array(await data.arrayBuffer()));
    return;
  }

  terminal.write(new Uint8Array(data));
};

export class BlobOnlyAttachAddon implements ITerminalAddon {
  private terminal?: Terminal;
  private dataDisposable?: { dispose: () => void };
  private readonly messageListener: (event: MessageEvent) => void;
  // Serializes writeSocketData calls so Blob conversion resolving out of arrival
  // order can't interleave terminal.write() output.
  private writeQueue: Promise<void> = Promise.resolve();

  constructor(private readonly socket: WebSocket) {
    this.messageListener = (event: MessageEvent) => {
      const terminal = this.terminal;
      if (!terminal) {
        return;
      }

      // Swallow per-write failures on the queue itself: once a chained promise
      // rejects, every later .then() on it skips silently, so one bad frame
      // would otherwise stop all future terminal output for the session.
      this.writeQueue = this.writeQueue.then(() =>
        writeSocketData(terminal, event.data as Blob | ArrayBuffer | string).catch(() => {}),
      );
    };
  }

  activate(terminal: Terminal): void {
    this.terminal = terminal;
    this.socket.binaryType = 'arraybuffer';
    this.socket.addEventListener('message', this.messageListener);
    this.dataDisposable = terminal.onData((data) => {
      if (this.socket.readyState === WebSocket.OPEN) {
        // Send as a binary frame — the server rejects text frames (e.g. it
        // would close the connection with "unexpected frame type read
        // (expected MessageBinary): MessageText" the instant a key is pressed).
        this.socket.send(new TextEncoder().encode(data));
      }
    });
  }

  dispose(): void {
    this.socket.removeEventListener('message', this.messageListener);
    this.dataDisposable?.dispose();
    this.terminal = undefined;
  }
}
