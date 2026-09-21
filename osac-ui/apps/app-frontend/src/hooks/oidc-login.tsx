import * as React from 'react';

import type { UserRole } from '@osac/ui-components/shellTypes';
import { getErrorMessage } from '@osac/ui-components/utils/error';

export const roleFromRoles = (roles: string[] = [], groups: string[] = []): UserRole => {
  if (groups.includes('admins') || roles.includes('cloud-provider-admin')) {
    return 'admin';
  }
  if (roles.includes('tenant-admin')) {
    return 'tenant-admin';
  }
  if (roles.includes('tenant-idp-manager')) {
    return 'tenant-idp-manager';
  }
  return 'tenant-user';
};

const fetchLoginInfo = async (): Promise<{
  username: string;
  roles: string[];
  groups: string[];
  tenantId: string;
} | null> => {
  try {
    const resp = await fetch('/api/login/info', { credentials: 'include' });
    if (resp.status === 401) {
      return null;
    }
    if (!resp.ok) {
      return null;
    }
    return (await resp.json()) as {
      username: string;
      roles: string[];
      groups: string[];
      tenantId: string;
    };
  } catch {
    return null;
  }
};

const EXPIRATION_KEY = 'osac.sessionExpiry';

const nowInSeconds = () => Math.round(Date.now() / 1000);

// max value for setTimeout
const maxTimeout = 2 ** 31 - 1;

export const useOIDCLogin = (): [
  string,
  UserRole,
  string,
  boolean,
  string | undefined,
  () => Promise<void>,
] => {
  const [triggerRelogin, setTriggerRelogin] = React.useState(0);
  const [isLoading, setIsLoading] = React.useState(true);
  const [username, setUsername] = React.useState<string>('');
  const [role, setRole] = React.useState<UserRole>('tenant-user');
  const [tenantId, setTenantId] = React.useState<string>('');
  const [error, setError] = React.useState<string>();

  const refreshTimerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);

  const scheduleRefresh = React.useCallback(() => {
    const expiresAt = parseInt(sessionStorage.getItem(EXPIRATION_KEY) || '0', 10);
    if (refreshTimerRef.current) {
      clearTimeout(refreshTimerRef.current);
    }
    if (expiresAt <= 0) {
      return;
    }
    const now = nowInSeconds();
    // refresh 15s before expiration
    const expiresIn = expiresAt - now - 15;
    const timeout = Math.min(maxTimeout, expiresIn * 1000);
    if (timeout > 0) {
      refreshTimerRef.current = setTimeout(async () => {
        try {
          const resp = await fetch('/api/login/refresh', { credentials: 'include' });
          if (!resp.ok) {
            return null;
          }
          const result = (await resp.json()) as { expiresIn: number };
          if (result) {
            sessionStorage.setItem(EXPIRATION_KEY, `${nowInSeconds() + result.expiresIn}`);
            scheduleRefresh();
          }
        } catch {
          return null;
        }
      }, timeout);
    }
  }, []);

  const loginInProgressRef = React.useRef(false);

  React.useEffect(() => {
    (async () => {
      if (loginInProgressRef.current) {
        return;
      }
      try {
        loginInProgressRef.current = true;
        let expiresIn = 1;
        if (window.location.pathname === '/callback') {
          localStorage.removeItem(EXPIRATION_KEY);
          const params = new URLSearchParams(window.location.search);
          const code = params.get('code');
          const state = params.get('state');
          const errorParam = params.get('error');
          const errorDescription = params.get('error_description');

          if (errorParam) {
            setError(errorDescription ?? errorParam);
            return;
          }
          if (!code || !state) {
            setError('Missing code or state in callback URL.');
            return;
          }

          try {
            const resp = await fetch(`/api/login?state=${encodeURIComponent(state)}`, {
              method: 'POST',
              credentials: 'include',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ code }),
            });
            if (!resp.ok) {
              const text = await resp.text().catch(() => '');
              throw new Error(text || `Login failed (HTTP ${resp.status})`);
            }
            expiresIn = ((await resp.json()) as { expiresIn: number }).expiresIn;
            sessionStorage.setItem(EXPIRATION_KEY, `${nowInSeconds() + expiresIn}`);
          } catch (err) {
            setError(getErrorMessage(err));
          }
        }
        const result = await fetchLoginInfo();
        if (result) {
          setError(undefined);
          setUsername(result.username);
          setRole(roleFromRoles(result.roles, result.groups));
          setTenantId(result.tenantId ?? '');
          setIsLoading(false);
          scheduleRefresh();
        } else {
          const redirectBase = encodeURIComponent(window.location.origin);
          try {
            const resp = await fetch(`/api/login?redirect_base=${redirectBase}`, {
              credentials: 'include',
            });
            if (!resp.ok) {
              const text = await resp.text().catch(() => '');
              setError(text || `Failed to start login (HTTP ${resp.status})`);
              return;
            }
            const { url } = (await resp.json()) as { url?: string };
            if (!url) {
              setError('No authorization URL returned by proxy');
              return;
            }
            window.location.href = url;
          } catch (e) {
            setError(`Failed to get login info: ${getErrorMessage(e)}`);
          }
        }
      } finally {
        loginInProgressRef.current = false;
      }
    })();
  }, [triggerRelogin, scheduleRefresh]);

  const logout = React.useCallback(async () => {
    const resp = await fetch('/api/logout', { method: 'POST', credentials: 'include' });
    if (!resp.ok) {
      let text = '';
      try {
        text = await resp.text();
      } catch (e) {
        // eslint-disable-next-line no-console
        console.warn('Failed to parse logout response', e);
      }
      throw new Error(`Logout failed (HTTP ${resp.status})${text ? `: ${text}` : ''}`);
    } else {
      setIsLoading(true);
      setTriggerRelogin((val) => val + 1);
    }
  }, []);

  return [username, role, tenantId, isLoading, error, logout];
};
