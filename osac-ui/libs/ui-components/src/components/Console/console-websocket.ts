import type { TFunction } from 'i18next';

export const CONSOLE_CLIENT_ID_STORAGE_KEY = 'osac-console-client-id';

const CONSOLE_CONNECT_PATH = '/api/fulfillment/v1/console_sessions/connect';

export const getConsoleWebSocketUrl = (): string => {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${protocol}//${window.location.host}${CONSOLE_CONNECT_PATH}`;
};

/**
 * Stable client id for this browser (not per-tab), persisted in localStorage so it
 * survives a full browser restart. Server sessions are keyed by VM endpoint, not by
 * client id, so one id per browser is enough — see console-proxy's eviction logic.
 */
export const getOrCreateConsoleClientId = (): string => {
  try {
    const existing = localStorage.getItem(CONSOLE_CLIENT_ID_STORAGE_KEY);
    if (existing) {
      return existing;
    }
    const id = crypto.randomUUID();
    localStorage.setItem(CONSOLE_CLIENT_ID_STORAGE_KEY, id);
    return id;
  } catch {
    return crypto.randomUUID();
  }
};

export interface ConsoleClientLock {
  release: () => void;
}

/**
 * Claims exclusive ownership of clientId for this tab via the Web Locks API, so the
 * automatic/silent connect path can tell whether another live tab is already using the
 * shared client id (and must not send it, or the server would evict that live tab).
 *
 * - Default (steal: false): non-blocking check. Resolves to a lock handle if no other
 *   tab currently holds it (safe to use), or null if another tab holds it live.
 * - steal: true: forcibly takes the lock even if another tab holds it. Used only for an
 *   explicit user-initiated "take over" — the browser itself releases the other tab's
 *   lock, it isn't just ignored client-side.
 *
 * The lock is held until `release()` is called (backed by a promise that only resolves
 * then) — release on disconnect/cleanup/takeover so a later automatic connect can regain
 * it correctly. Falls back to "always available" when the Web Locks API is unsupported.
 */
export const acquireConsoleClientLock = (
  clientId: string,
  { steal = false }: { steal?: boolean } = {},
): Promise<ConsoleClientLock | null> => {
  if (!('locks' in navigator)) {
    return Promise.resolve({ release: () => {} });
  }

  return new Promise((resolve) => {
    navigator.locks
      .request(clientId, steal ? { steal: true } : { ifAvailable: true }, (lock) => {
        if (!lock) {
          resolve(null);
          return undefined;
        }
        return new Promise<void>((release) => {
          resolve({ release });
        });
      })
      .catch(() => resolve(null));
  });
};

/**
 * The console-ticket cookie is HttpOnly — the proxy sets it from the
 * ConsoleSessions.Create response headers, so this browser can neither read
 * nor delete it via document.cookie. This asks the proxy to delete it
 * server-side instead; fire-and-forget since there is nothing to await.
 */
export const clearConsoleTicketCookie = (): void => {
  fetch('/api/console-ticket/clear', { method: 'POST' }).catch(() => {});
};

export const openConsoleWebSocket = (): WebSocket =>
  new WebSocket(getConsoleWebSocketUrl(), ['binary']);

export const getWebSocketCloseErrorMessage = (event: CloseEvent, t: TFunction): string => {
  if (event.reason) {
    return event.reason;
  }

  if (event.code === 1006) {
    return t('Console connection was closed unexpectedly');
  }

  return t('Console connection closed (code {{code}})', { code: event.code });
};
