// @refresh reload — hook signature changes in this module cannot be Fast-Refreshed safely
import { useCallback, useEffect, useRef, useState } from 'react';

import { type ConsoleResourceType, ConsoleType } from '@osac/types';

import {
  type ConsoleClientLock,
  acquireConsoleClientLock,
  clearConsoleTicketCookie,
  getOrCreateConsoleClientId,
  getWebSocketCloseErrorMessage,
  openConsoleWebSocket,
} from './console-websocket';
import type { ConsoleUiConnectionState } from './console.types';
import { useCreateConsoleSession } from '../../api/v1/console-session';
import { useTranslation } from '../../hooks/useTranslation';

/**
 * Distinguishes why errorMessage is set, so the UI can decide whether takeOver is a
 * relevant recovery action. takeOver only ever sends this browser's persisted client id —
 * exactly what connect() already sends — so it can only change the outcome (by forcing
 * the local Web Lock) when the conflicting session was created with that same persisted
 * id, i.e. by this same browser. That is true for 'siblingTabConflict' and nothing else,
 * so it is the only kind that offers takeOver:
 * - 'siblingTabConflict': a live sibling tab in this browser is confirmed to hold this
 *   resource's console. takeOver is guaranteed to work (same browser, same persisted id).
 * - 'possibleConflict': the WebSocket closed before it ever opened. The browser hides the
 *   real HTTP status of a failed handshake, so this *might* be a session already owned
 *   elsewhere — but takeOver would resend the identical request connect() already sent,
 *   so it cannot do anything a plain reconnect wouldn't, and is not offered.
 * - 'viewer': the error came from the VNC viewer (rendering/protocol failure), not the
 *   connection — the console session is fine, so takeOver (which evicts a session) is not
 *   a relevant recovery action and no action is offered.
 * - 'generic': anything else (ticket creation failed, or an established connection later
 *   dropped) — there is no reason to suspect another session, so no action is offered.
 */
export type ConsoleErrorKind = 'generic' | 'possibleConflict' | 'siblingTabConflict' | 'viewer';

export interface UseConsoleSessionParams {
  resourceType: ConsoleResourceType;
  resourceId: string;
  /** Whether the resource can currently accept a console connection. */
  isRunning: boolean;
  /** Which console transport to mint the ticket for (VNC or serial). */
  consoleType: ConsoleType;
}

export interface UseConsoleSessionResult {
  connectionState: ConsoleUiConnectionState;
  /**
   * Creates a ticket and opens the WebSocket for this resource, without disturbing
   * another active session, if any. This hook never calls it automatically — the caller
   * decides when to (typically once the viewer is ready to attach to the socket; see
   * VmConsoleTab, which awaits the noVNC viewer code before calling this).
   */
  connect: () => void;
  errorMessage: string | null;
  /** Only meaningful while errorMessage is set. */
  errorKind: ConsoleErrorKind;
  reportViewerError: (message: string) => void;
  /** Evicts the other session (if any) and reconnects, using this browser's shared client id. */
  takeOver: () => void;
  webSocket: WebSocket | null;
}

export const useConsoleSession = ({
  resourceType,
  resourceId,
  isRunning,
  consoleType,
}: UseConsoleSessionParams): UseConsoleSessionResult => {
  const { t } = useTranslation();
  // The browser hides the HTTP status of a failed WebSocket handshake entirely (fires a
  // generic 'error' then 'close(1006, "")' no matter what the server actually returned),
  // so there is no reliable way to tell "another session already owns this console" apart
  // from any other connection failure — a plain fetch() probe can't reach the
  // differentiating status either, since the trusted proxy in front of console-proxy
  // requires an Origin header for this path, which browsers never send on a same-origin
  // fetch. No action is offered for this case (see ConsoleErrorKind) — this text is
  // informational only.
  const possibleConflictMessage = t(
    'This might be because the console is already open in another session.',
  );
  // Shown instead of possibleConflictMessage when this browser's own per-resource lock
  // was already held at connect time — the Web Locks API only frees a lock when its
  // holding tab is genuinely gone (crash or clean close), so "unavailable" means a
  // sibling tab is actively using this exact resource's console right now. Take over is
  // guaranteed to work here (same browser, same persisted id), unlike the
  // possible-conflict case.
  const siblingTabConflictMessage = t(
    'This console is already open in another tab in this browser. Take over to continue here, or switch to that tab.',
  );
  // Fallback for the rare case where connect() throws a non-Error value — real failures
  // always throw an Error (see the explicit throw below and createSession's rejection
  // shape), so this text is never about a conflict and offers no action.
  const genericConnectFailedMessage = t('Failed to connect to the console.');
  const createSession = useCreateConsoleSession();
  const socketRef = useRef<WebSocket | null>(null);
  const lockRef = useRef<ConsoleClientLock | null>(null);
  // Bumped whenever the current connect attempt is superseded (cleanup fires, e.g. a
  // StrictMode phantom mount or a genuine unmount). Every socket event handler and
  // post-await check compares against the sessionId it captured — a mismatch means this
  // callback belongs to an abandoned attempt and must not touch state or the socket.
  const sessionIdRef = useRef(0);
  const [connectionState, setConnectionState] = useState<ConsoleUiConnectionState>('idle');
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [errorKind, setErrorKind] = useState<ConsoleErrorKind>('generic');
  const [webSocket, setWebSocket] = useState<WebSocket | null>(null);

  const releaseLock = () => {
    lockRef.current?.release();
    lockRef.current = null;
  };

  // The viewer can fail while the WebSocket is still open (e.g. noVNC protocol
  // error), so this mirrors the cleanup the close listener and the connect catch
  // block already do — otherwise the socket and Web Lock would stay alive despite
  // the UI reporting a failed console, leaving a stale server-side session that
  // causes spurious sibling-tab conflicts on retry.
  const reportViewerError = useCallback((message: string) => {
    // Invalidate the in-flight session first, same as the unmount cleanup below —
    // otherwise the socket's own 'close' listener (still attached, still passing its
    // isCurrentSession() check) fires once close() completes and overwrites the
    // 'viewer' error state set here with its own generic close message.
    sessionIdRef.current += 1;
    releaseLock();
    const socket = socketRef.current;
    socketRef.current = null;
    setWebSocket(null);
    clearConsoleTicketCookie();
    socket?.close();
    setConnectionState('error');
    setErrorMessage(message);
    setErrorKind('viewer');
  }, []);

  // force=false (plain connect): only proceeds if no other live tab currently holds this
  // resource's lock — sending the shared id while one does would let the server evict
  // that live tab, so this skips connecting entirely instead (see the sibling-tab check
  // below). force=true (explicit "take over"): steals the lock and always sends the
  // shared id, evicting whatever session — this tab's own stale one, or another tab's
  // live one — currently owns the console.
  const attemptConnect = async (force: boolean) => {
    if (!isRunning) {
      return;
    }

    const sessionId = ++sessionIdRef.current;
    const isCurrentSession = () => sessionIdRef.current === sessionId;

    releaseLock();
    setConnectionState('connecting');
    setErrorMessage(null);
    setErrorKind('generic');

    const persistedClientId = getOrCreateConsoleClientId();
    // Scoped per resource (not just per browser) so "unavailable" specifically means a
    // sibling tab has *this* resource's console open — not just any console tab anywhere.
    const lockName = `${persistedClientId}:${resourceType}:${resourceId}`;
    const lock = await acquireConsoleClientLock(lockName, { steal: force });
    if (!isCurrentSession()) {
      lock?.release();
      return;
    }

    // Web Locks are only freed when the holding tab is genuinely gone (crash or clean
    // close), so finding it unavailable here (never happens when force=true — steal
    // always grants) means a live sibling tab has this exact resource's console open
    // right now. Connecting anyway would just fail with the same predictable conflict,
    // so skip the wasted ticket mint and WebSocket round trip and go straight to the one
    // message that's actually true and actionable.
    if (!lock) {
      setConnectionState('error');
      setErrorMessage(siblingTabConflictMessage);
      setErrorKind('siblingTabConflict');
      return;
    }
    lockRef.current = lock;

    try {
      await createSession.mutateAsync({
        resourceType,
        resourceId,
        clientId: persistedClientId,
        type: consoleType,
      });
      if (!isCurrentSession()) {
        return;
      }

      // The proxy already set the console-ticket cookie (HttpOnly, via the
      // Create response headers) by the time this resolves — the ticket
      // itself is stripped from the response body and never reaches this code.
      const socket = openConsoleWebSocket();
      socketRef.current = socket;
      setWebSocket(socket);

      let hasOpened = false;
      socket.addEventListener('open', () => {
        if (!isCurrentSession()) {
          return;
        }
        hasOpened = true;
        setConnectionState('connected');
      });
      socket.addEventListener('close', (event) => {
        if (!isCurrentSession()) {
          return;
        }

        socketRef.current = null;
        setWebSocket(null);
        clearConsoleTicketCookie();
        releaseLock();

        const wasConnecting = !hasOpened;
        setConnectionState('error');
        if (wasConnecting) {
          setErrorMessage(possibleConflictMessage);
          setErrorKind('possibleConflict');
        } else {
          setErrorMessage(getWebSocketCloseErrorMessage(event, t));
          setErrorKind('generic');
        }
      });
      // No listener needed: WebSocket 'error' carries no diagnostic info (no code/reason)
      // and is always immediately followed by 'close', which does — and which owns all
      // error-state handling above.
    } catch (error) {
      if (!isCurrentSession()) {
        return;
      }
      releaseLock();
      clearConsoleTicketCookie();
      setConnectionState('error');
      setErrorMessage(error instanceof Error ? error.message : genericConnectFailedMessage);
      setErrorKind('generic');
    }
  };

  const attemptConnectRef = useRef(attemptConnect);
  attemptConnectRef.current = attemptConnect;

  const connect = useCallback(() => {
    void attemptConnectRef.current(false);
  }, []);

  const takeOver = useCallback(() => {
    void attemptConnectRef.current(true);
  }, []);

  // This hook never calls connect() itself — only cleans up (releasing the lock, closing
  // the socket, clearing the ticket cookie) whenever isRunning flips to false or the
  // component unmounts while it was true. resourceType/resourceId changes are not
  // tracked — a different resource is expected to remount this hook.
  useEffect(() => {
    if (!isRunning) {
      return;
    }

    return () => {
      sessionIdRef.current += 1;
      releaseLock();
      const socket = socketRef.current;
      socketRef.current = null;
      setWebSocket(null);
      setConnectionState('disconnected');
      setErrorMessage(null);
      setErrorKind('generic');
      clearConsoleTicketCookie();
      // Close after clearing the ref so the async `close` event is ignored as stale.
      socket?.close();
    };
    // Only isRunning is tracked (see comment above) — resourceType/resourceId/
    // createSession are intentionally omitted.
  }, [isRunning]);

  return {
    connectionState,
    connect,
    errorMessage,
    errorKind,
    reportViewerError,
    takeOver,
    webSocket,
  };
};
