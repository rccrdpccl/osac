import { forwardRef, useEffect, useImperativeHandle, useRef } from 'react';
import type { FitAddon } from '@xterm/addon-fit';
import type { Terminal } from '@xterm/xterm';

import { BlobOnlyAttachAddon } from './BlobOnlyAttachAddon';
import { CONSOLE_VIEWPORT_CLASS_NAME } from './console-viewport';
import { loadXtermConstructors } from './xterm-loader';
import { useTranslation } from '../../hooks/useTranslation';

import './SerialConsoleViewer.css';
import '@xterm/xterm/css/xterm.css';

export interface SerialConsoleViewerHandle {
  focus: () => void;
  pasteFromClipboard: () => Promise<void>;
}

interface Props {
  className?: string;
  onConnected?: () => void;
  onError?: (message: string) => void;
  webSocket: WebSocket | null;
}

const fitIfSized = (container: HTMLElement, fitAddon: FitAddon) => {
  if (container.clientWidth > 0 && container.clientHeight > 0) {
    fitAddon.fit();
  }
};

const SerialConsoleViewer = forwardRef<SerialConsoleViewerHandle, Props>(
  ({ className, onConnected, onError, webSocket }, ref) => {
    const { t } = useTranslation();
    const containerRef = useRef<HTMLDivElement>(null);
    const terminalRef = useRef<Terminal | undefined>(undefined);
    const fitAddonRef = useRef<FitAddon | undefined>(undefined);
    // Computed here (where the i18next-cli extractor's static scan can see the
    // translation call) and read via ref inside the effect below instead of
    // listing t as a dependency: t's identity can change mid-session while
    // translations are still loading, and that must not re-run the effect (which
    // disposes and rebuilds the terminal, dropping an attached console).
    const loadFailedMessage = t('Failed to load serial console viewer');
    const loadFailedMessageRef = useRef(loadFailedMessage);
    loadFailedMessageRef.current = loadFailedMessage;
    // Read via refs inside the effect for the same reason as VncConsoleViewer: a
    // parent re-render can hand down new callback identities without meaning to
    // restart the session, and the effect cleanup disposes the terminal.
    const onConnectedRef = useRef(onConnected);
    onConnectedRef.current = onConnected;
    const onErrorRef = useRef(onError);
    onErrorRef.current = onError;

    useImperativeHandle(ref, () => ({
      focus: () => {
        terminalRef.current?.focus();
      },
      pasteFromClipboard: async () => {
        const text = await navigator.clipboard.readText();
        terminalRef.current?.paste(text);
      },
    }));

    useEffect(() => {
      if (!containerRef.current || !webSocket) {
        return;
      }

      const container = containerRef.current;
      const socket = webSocket;
      let mounted = true;
      let onSocketOpen: (() => void) | undefined;

      const markConnected = () => {
        if (!mounted) {
          return;
        }
        // Focus so keystrokes reach the guest without an extra click.
        terminalRef.current?.focus();
        onConnectedRef.current?.();
      };

      const init = async () => {
        try {
          const { Terminal, FitAddon } = await loadXtermConstructors();
          if (!mounted || terminalRef.current) {
            return;
          }

          const terminal = new Terminal({ cursorBlink: true });
          const fitAddon = new FitAddon();
          terminal.loadAddon(fitAddon);
          terminal.open(container);
          terminal.loadAddon(new BlobOnlyAttachAddon(socket));
          terminalRef.current = terminal;
          fitAddonRef.current = fitAddon;
          fitIfSized(container, fitAddon);

          if (socket.readyState === WebSocket.OPEN) {
            markConnected();
          } else {
            onSocketOpen = markConnected;
            socket.addEventListener('open', onSocketOpen, { once: true });
          }
        } catch (error: unknown) {
          if (!mounted) {
            return;
          }
          const message = error instanceof Error ? error.message : loadFailedMessageRef.current;
          onErrorRef.current?.(message);
        }
      };

      void init();

      const resizeObserver = new ResizeObserver(() => {
        if (fitAddonRef.current) {
          fitIfSized(container, fitAddonRef.current);
        }
      });
      resizeObserver.observe(container);

      return () => {
        mounted = false;
        resizeObserver.disconnect();
        if (onSocketOpen) {
          socket.removeEventListener('open', onSocketOpen);
        }
        // Disposing the terminal also disposes its loaded addons, so the
        // BlobOnlyAttachAddon removes its own socket 'message' listener.
        terminalRef.current?.dispose();
        terminalRef.current = undefined;
        fitAddonRef.current = undefined;
      };
      // onConnected/onError/t are read via refs above and intentionally omitted.
    }, [webSocket]);

    const rootClassName = [CONSOLE_VIEWPORT_CLASS_NAME, className].filter(Boolean).join(' ');

    return <div ref={containerRef} className={rootClassName} data-testid="serial-console-viewer" />;
  },
);

SerialConsoleViewer.displayName = 'SerialConsoleViewer';

export default SerialConsoleViewer;
