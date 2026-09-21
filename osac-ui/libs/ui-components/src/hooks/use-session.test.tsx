import { MemoryRouter, useNavigate } from 'react-router-dom';
import { act, renderHook } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { SessionProvider, useSession } from './use-session';

const makeWrapper = (initialEntries: string[] = ['/']) => {
  const Wrapper = ({ children }: { children: React.ReactNode }) => (
    <MemoryRouter initialEntries={initialEntries}>
      <SessionProvider role="tenant-user" username="alice" tenantId="t-123">
        {children}
      </SessionProvider>
    </MemoryRouter>
  );
  return Wrapper;
};

describe('useSession', () => {
  it('exposes tenantId from provider', () => {
    const { result } = renderHook(() => useSession(), { wrapper: makeWrapper() });

    expect(result.current.tenantId).toBe('t-123');
    expect(result.current.username).toBe('alice');
    expect(result.current.role).toBe('tenant-user');
  });

  it('exposes an empty tenantId when provider receives an empty string', () => {
    const wrapper = ({ children }: { children: React.ReactNode }) => (
      <MemoryRouter>
        <SessionProvider role="admin" username="bob" tenantId="">
          {children}
        </SessionProvider>
      </MemoryRouter>
    );

    const { result } = renderHook(() => useSession(), { wrapper });

    expect(result.current.tenantId).toBe('');
  });

  it('throws when used outside SessionProvider', () => {
    expect(() => {
      renderHook(() => useSession());
    }).toThrow('useSession must be used inside SessionProvider');
  });

  it('initializes projects from the URL param', () => {
    const { result } = renderHook(() => useSession(), {
      wrapper: makeWrapper(['/?project=a,b']),
    });

    expect(result.current.projects).toEqual(['a', 'b']);
  });

  it('does not re-read the URL param after mount', () => {
    const { result } = renderHook(() => ({ session: useSession(), navigate: useNavigate() }), {
      wrapper: makeWrapper(['/?project=a']),
    });

    expect(result.current.session.projects).toEqual(['a']);

    // The selection is owned by state: navigation must not change it. Callers
    // that want a different selection call setProjects before navigating.
    act(() => {
      result.current.navigate('/?project=b,c');
    });

    expect(result.current.session.projects).toEqual(['a']);
  });
});
