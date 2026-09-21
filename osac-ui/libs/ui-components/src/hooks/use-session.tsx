import { createContext, useCallback, useContext, useState } from 'react';
import { useSearchParams } from 'react-router-dom';

import type { UserRole } from '../shellTypes';
import {
  type Contrast,
  type ResolvedContrast,
  type ResolvedTheme,
  type Theme,
  useTheme,
} from './use-theme';
import { useUserPreferences } from './use-user-preferences';

interface SessionContextValue {
  role: UserRole;
  username: string;
  tenantId: string;
  userTheme: Theme;
  resolvedTheme: ResolvedTheme;
  setUserTheme: (theme: Theme) => void;
  userContrast: Contrast;
  resolvedContrast: ResolvedContrast;
  setUserContrast: (contrast: Contrast) => void;
  projects: string[];
  setProjects: (projects: string[]) => void;
}

const SessionContext = createContext<SessionContextValue | null>(null);

interface SessionProviderProps {
  children: React.ReactNode;
  role: UserRole;
  username: string;
  tenantId: string;
}

export const PROJECT_FILTER_PARAM = 'project';

/** localStorage key prefix for the per-user persisted project filter selection. */
export const PROJECT_FILTER_STORAGE_PREFIX = 'osac/project-filter/';

export const getProjectFilterStorageKey = (username: string) =>
  `${PROJECT_FILTER_STORAGE_PREFIX}${username}`;

export const SessionProvider = ({ children, role, username, tenantId }: SessionProviderProps) => {
  const themeProps = useTheme();

  const [searchParams] = useSearchParams();
  const param = searchParams.get(PROJECT_FILTER_PARAM);

  // Persist the selection per user so it is recovered on the next visit. An
  // explicit URL param wins over the stored value so shared/deep links behave.
  const [storedProjects, setStoredProjects] = useUserPreferences(
    getProjectFilterStorageKey(username),
  );

  const [projects, setProjectsState] = useState<string[]>(() => {
    const initial = param ?? storedProjects;
    return initial ? initial.split(',') : [];
  });

  const setProjects = useCallback(
    (next: string[]) => {
      setProjectsState(next);
      setStoredProjects(next.join(','));
    },
    [setStoredProjects],
  );

  return role ? (
    <SessionContext.Provider
      value={{
        role,
        username,
        tenantId,
        projects,
        setProjects,
        ...themeProps,
      }}
    >
      {children}
    </SessionContext.Provider>
  ) : undefined;
};

export const useSession = (): SessionContextValue => {
  const ctx = useContext(SessionContext);
  if (!ctx) {
    throw new Error('useSession must be used inside SessionProvider');
  }

  return ctx;
};
