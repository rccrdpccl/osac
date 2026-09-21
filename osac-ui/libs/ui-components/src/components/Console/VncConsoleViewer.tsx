import { forwardRef, useEffect, useImperativeHandle, useRef } from 'react';

import { CONSOLE_VIEWPORT_CLASS_NAME } from './console-viewport';
import { type VncRfbInstance, loadVncRfbConstructor } from './novnc-rfb';
import { pasteFromClipboard } from './paste-from-clipboard';
import { useTranslation } from '../../hooks/useTranslation';

import './VncConsoleViewer.css';

export interface VncConsoleViewerHandle {
  focus: () => void;
  pasteFromClipboard: () => Promise<void>;
}

interface Props {
  className?: string;
  onConnected?: () => void;
  onError?: (message: string) => void;
  webSocket: WebSocket | null;
}

/** How long to wait for a non-zero viewport before giving up on RFB init. */
export const RFB_INIT_TIMEOUT_MS = 30_000;
/** How long to wait for noVNC `connect` after RFB is constructed. */
export const RFB_CONNECT_TIMEOUT_MS = 30_000;

const VncConsoleViewer = forwardRef<VncConsoleViewerHandle, Props>(
  ({ className, onConnected, onError, webSocket }, ref) => {
    const { t } = useTranslation();
    const containerRef = useRef<HTMLDivElement>(null);
    const rfbRef = useRef<VncRfbInstance | undefined>(undefined);
    // Computed here (where the i18next-cli extractor's static scan can see the translation
    // calls) and read via ref inside the effect below instead of listing t itself as a
    // dependency: t's identity can change mid-session while i18next-http-backend is still
    // loading translations, and that must not re-trigger this effect — the cleanup calls
    // rfb.disconnect(), which would visibly drop an already-connected console.
    const messages = {
      disconnected: t('Graphical console disconnected'),
      disconnectedBeforeConnecting: t(
        'Graphical console disconnected before it finished connecting',
      ),
      connectTimedOut: t('Timed out waiting for the graphical console to finish connecting'),
      loadFailed: t('Failed to load graphical console viewer'),
      noSize: t('Graphical console viewer could not start because the display area has no size'),
    };
    const messagesRef = useRef(messages);
    messagesRef.current = messages;
    // Read via refs inside the effect below instead of listing onConnected/onError as
    // dependencies: a parent re-render can hand down a new function identity for these
    // (e.g. an inline callback) without meaning to restart the console session, and the
    // effect's cleanup calls rfb.disconnect(), which would visibly drop an
    // already-connected console.
    const onConnectedRef = useRef(onConnected);
    onConnectedRef.current = onConnected;
    const onErrorRef = useRef(onError);
    onErrorRef.current = onError;

    useImperativeHandle(ref, () => ({
      focus: () => {
        rfbRef.current?.focus();
      },
      pasteFromClipboard: async () => {
        const rfb = rfbRef.current;
        if (rfb) {
          await pasteFromClipboard(rfb, () => rfbRef.current === rfb);
        }
      },
    }));

    useEffect(() => {
      if (!containerRef.current || !webSocket) {
        return;
      }

      const container = containerRef.current;
      let mounted = true;
      let initInFlight = false;
      let connectTimeoutId: number | undefined;
      // This listener stays registered for the RFB instance's whole lifetime, not just
      // during the initial handshake, so a later disconnect (guest shutdown, dropped
      // network mid-session) must not report the handshake-specific message below.
      let hasConnectedOnce = false;
      const onConnect = () => {
        if (!mounted) {
          return;
        }
        window.clearTimeout(connectTimeoutId);
        hasConnectedOnce = true;
        // Focus so keyboard input goes to the guest without an extra click.
        rfbRef.current?.focus();
        onConnectedRef.current?.();
      };
      const onDisconnect = () => {
        if (!mounted) {
          return;
        }
        window.clearTimeout(connectTimeoutId);
        onErrorRef.current?.(
          hasConnectedOnce
            ? messagesRef.current.disconnected
            : messagesRef.current.disconnectedBeforeConnecting,
        );
      };

      const initRfb = async () => {
        if (
          !mounted ||
          initInFlight ||
          rfbRef.current ||
          container.clientWidth === 0 ||
          container.clientHeight === 0
        ) {
          return;
        }

        initInFlight = true;
        try {
          const RFB = await loadVncRfbConstructor();
          if (
            !mounted ||
            rfbRef.current ||
            container.clientWidth === 0 ||
            container.clientHeight === 0
          ) {
            return;
          }

          window.clearTimeout(initTimeoutId);
          const rfb = new RFB(container, webSocket);
          rfb.scaleViewport = true;
          rfb.background = 'rgb(40, 40, 40)';
          rfb.addEventListener('connect', onConnect);
          rfb.addEventListener('disconnect', onDisconnect);
          rfbRef.current = rfb;
          connectTimeoutId = window.setTimeout(() => {
            if (!mounted || rfbRef.current !== rfb) {
              return;
            }
            onErrorRef.current?.(messagesRef.current.connectTimedOut);
          }, RFB_CONNECT_TIMEOUT_MS);
        } catch (error: unknown) {
          if (!mounted) {
            return;
          }

          window.clearTimeout(initTimeoutId);
          const message = error instanceof Error ? error.message : messagesRef.current.loadFailed;
          onErrorRef.current?.(message);
        } finally {
          initInFlight = false;
        }
      };

      const initTimeoutId = window.setTimeout(() => {
        if (!mounted || rfbRef.current) {
          return;
        }
        onErrorRef.current?.(messagesRef.current.noSize);
      }, RFB_INIT_TIMEOUT_MS);

      void initRfb();
      const resizeObserver = new ResizeObserver(() => {
        void initRfb();
        if (rfbRef.current) {
          window.dispatchEvent(new Event('resize'));
        }
      });
      resizeObserver.observe(container);

      return () => {
        mounted = false;
        window.clearTimeout(initTimeoutId);
        window.clearTimeout(connectTimeoutId);
        resizeObserver.disconnect();
        rfbRef.current?.removeEventListener('connect', onConnect);
        rfbRef.current?.removeEventListener('disconnect', onDisconnect);
        rfbRef.current?.disconnect();
        rfbRef.current = undefined;
      };
      // onConnected/onError are read via refs above and intentionally omitted — see the
      // comment where those refs are declared.
    }, [webSocket]);

    const rootClassName = [CONSOLE_VIEWPORT_CLASS_NAME, className].filter(Boolean).join(' ');

    return <div ref={containerRef} className={rootClassName} data-testid="vnc-console-viewer" />;
  },
);

VncConsoleViewer.displayName = 'VncConsoleViewer';

export default VncConsoleViewer;
