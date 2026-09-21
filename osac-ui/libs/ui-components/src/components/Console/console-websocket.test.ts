import type { TFunction } from 'i18next';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  acquireConsoleClientLock,
  clearConsoleTicketCookie,
  getConsoleWebSocketUrl,
  getOrCreateConsoleClientId,
  getWebSocketCloseErrorMessage,
  openConsoleWebSocket,
} from './console-websocket';

// Mimics react-i18next's {{placeholder}} interpolation for this file's one
// interpolated message, without needing a real i18n instance in this unit test.
const t = ((key: string, options?: { code?: number }) =>
  options?.code !== undefined ? key.replace('{{code}}', String(options.code)) : key) as TFunction;

describe('console-websocket', () => {
  beforeEach(() => {
    sessionStorage.clear();
    localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('builds a wss URL when the page is served over https', () => {
    vi.stubGlobal('window', {
      location: {
        protocol: 'https:',
        host: 'console.example.com',
      },
    });

    expect(getConsoleWebSocketUrl()).toBe(
      'wss://console.example.com/api/fulfillment/v1/console_sessions/connect',
    );
  });

  it('asks the proxy to clear the console-ticket cookie', () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(null, { status: 204 }));
    vi.stubGlobal('fetch', fetchMock);

    clearConsoleTicketCookie();

    expect(fetchMock).toHaveBeenCalledWith('/api/console-ticket/clear', { method: 'POST' });
  });

  it('opens a WebSocket with the binary subprotocol', () => {
    const webSocketCtor = vi.fn();
    vi.stubGlobal('WebSocket', webSocketCtor);
    vi.stubGlobal('window', {
      location: {
        protocol: 'http:',
        host: 'localhost:5173',
      },
    });

    openConsoleWebSocket();

    expect(webSocketCtor).toHaveBeenCalledWith(
      'ws://localhost:5173/api/fulfillment/v1/console_sessions/connect',
      ['binary'],
    );
  });

  it('creates a client id once and persists it across calls', () => {
    const first = getOrCreateConsoleClientId();
    const second = getOrCreateConsoleClientId();

    expect(first).toBe(second);
    expect(localStorage.getItem('osac-console-client-id')).toBe(first);
  });

  type LockRequestMock = (
    name: string,
    options: LockOptions,
    callback: (lock: Lock | null) => Promise<unknown>,
  ) => Promise<unknown>;

  it('acquires the lock when no other tab holds it', async () => {
    const requestMock = vi.fn<LockRequestMock>((_name, _options, callback) => callback({} as Lock));
    vi.stubGlobal('navigator', { locks: { request: requestMock } });

    const lock = await acquireConsoleClientLock('client-a');

    expect(lock).not.toBeNull();
    expect(requestMock).toHaveBeenCalledWith(
      'client-a',
      { ifAvailable: true },
      expect.any(Function),
    );
  });

  it('does not acquire the lock when another tab already holds it', async () => {
    const requestMock = vi.fn<LockRequestMock>((_name, _options, callback) => callback(null));
    vi.stubGlobal('navigator', { locks: { request: requestMock } });

    const lock = await acquireConsoleClientLock('client-a');

    expect(lock).toBeNull();
  });

  it('steals the lock when force is requested', async () => {
    const requestMock = vi.fn<LockRequestMock>((_name, _options, callback) => callback({} as Lock));
    vi.stubGlobal('navigator', { locks: { request: requestMock } });

    const lock = await acquireConsoleClientLock('client-a', { steal: true });

    expect(lock).not.toBeNull();
    expect(requestMock).toHaveBeenCalledWith('client-a', { steal: true }, expect.any(Function));
  });

  it('falls back to always-available when the Web Locks API is unsupported', async () => {
    vi.stubGlobal('navigator', {});

    const lock = await acquireConsoleClientLock('client-a');

    expect(lock).not.toBeNull();
  });

  it('describes WebSocket close failures', () => {
    expect(getWebSocketCloseErrorMessage({ code: 1006, reason: '' } as CloseEvent, t)).toBe(
      'Console connection was closed unexpectedly',
    );
    expect(getWebSocketCloseErrorMessage({ code: 1002, reason: '' } as CloseEvent, t)).toBe(
      'Console connection closed (code 1002)',
    );
    expect(
      getWebSocketCloseErrorMessage({ code: 1008, reason: 'origin not allowed' } as CloseEvent, t),
    ).toBe('origin not allowed');
  });
});
