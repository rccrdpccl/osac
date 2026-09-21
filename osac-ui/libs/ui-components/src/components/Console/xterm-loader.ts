import type { FitAddon } from '@xterm/addon-fit';
import type { Terminal } from '@xterm/xterm';

export interface XtermConstructors {
  Terminal: typeof Terminal;
  FitAddon: typeof FitAddon;
}

/**
 * Dynamically imports xterm.js and its fit addon. Callers should await this
 * *before* creating the console WebSocket (see VmConsoleView), not after:
 * BlobOnlyAttachAddon.activate() subscribes to the socket's 'message' events
 * synchronously when the viewer mounts, so any guest bytes delivered before the
 * addon is attached are lost. Pre-loading removes the dynamic-import delay from
 * that window. The imports are module-cached, so calling this again when
 * SerialConsoleViewer mounts resolves instantly.
 */
export const loadXtermConstructors = async (): Promise<XtermConstructors> => {
  const [{ Terminal }, { FitAddon }] = await Promise.all([
    import('@xterm/xterm'),
    import('@xterm/addon-fit'),
  ]);

  return { Terminal, FitAddon };
};
