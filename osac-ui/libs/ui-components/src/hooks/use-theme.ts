import * as React from 'react';

import { useUserPreferences } from './use-user-preferences';

export const THEME_LOCAL_STORAGE_KEY = 'osac/theme';
export const CONTRAST_LOCAL_STORAGE_KEY = 'osac/contrast';

const THEME_DARK_CLASS = 'pf-v6-theme-dark';
const THEME_GLASS_CLASS = 'pf-v6-theme-glass';
const THEME_CONTRAST_CLASS = 'pf-v6-theme-high-contrast';
/** OpenShift Felt brand tokens — always on, matching Console (non-OKD). */
const THEME_FELT_CLASS = 'pf-v6-theme-felt';

export type Theme = 'dark' | 'light' | 'system';
export type ResolvedTheme = Exclude<Theme, 'system'>;

/** Contrast preference values mirror OpenShift Console (system / glass / traditional / high contrast). */
export type Contrast = 'system' | 'glass' | 'default' | 'contrast';
export type ResolvedContrast = Exclude<Contrast, 'system'>;

const getTheme = (storageTheme: string | null): Theme => {
  switch (storageTheme) {
    case 'dark': {
      return 'dark';
    }
    case 'light': {
      return 'light';
    }
    default: {
      return 'system';
    }
  }
};

const getContrast = (storageContrast: string | null): Contrast => {
  switch (storageContrast) {
    case 'glass':
    case 'default':
    case 'contrast': {
      return storageContrast;
    }
    default: {
      return 'system';
    }
  }
};

const getDarkThemeMq = () => window.matchMedia('(prefers-color-scheme: dark)');

const getHighContrastMq = () => window.matchMedia('(prefers-contrast: more)');

const getResolvedTheme = (darkThemeMq: MediaQueryList, theme: string | null): ResolvedTheme => {
  const isDarkPreferred = darkThemeMq.matches;
  return theme === 'dark' || (isDarkPreferred && getTheme(theme) === 'system') ? 'dark' : 'light';
};

const getResolvedContrast = (
  highContrastMq: MediaQueryList,
  contrast: string | null,
): ResolvedContrast => {
  const preference = getContrast(contrast);
  if (preference === 'system') {
    return highContrastMq.matches ? 'contrast' : 'glass';
  }
  return preference;
};

export const updateThemeClass = (
  htmlTagElement: HTMLElement,
  resolvedTheme: ResolvedTheme,
  resolvedContrast: ResolvedContrast,
) => {
  htmlTagElement.classList.add(THEME_FELT_CLASS);
  htmlTagElement.classList.toggle(THEME_DARK_CLASS, resolvedTheme === 'dark');
  htmlTagElement.classList.toggle(THEME_GLASS_CLASS, resolvedContrast === 'glass');
  htmlTagElement.classList.toggle(THEME_CONTRAST_CLASS, resolvedContrast === 'contrast');
};

export const useTheme = () => {
  const htmlTagElement = document.documentElement;
  const [userTheme, setUserTheme] = useUserPreferences(THEME_LOCAL_STORAGE_KEY);
  const [userContrast, setUserContrast] = useUserPreferences(CONTRAST_LOCAL_STORAGE_KEY);
  const [resolvedTheme, setResolvedTheme] = React.useState<ResolvedTheme>('light');
  const [resolvedContrast, setResolvedContrast] = React.useState<ResolvedContrast>('glass');

  React.useEffect(() => {
    const currentTheme = getTheme(userTheme);
    const currentContrast = getContrast(userContrast);
    const darkThemeMq = getDarkThemeMq();
    const highContrastMq = getHighContrastMq();

    const applyTheme = (
      nextResolvedTheme: ResolvedTheme,
      nextResolvedContrast: ResolvedContrast,
    ) => {
      updateThemeClass(htmlTagElement, nextResolvedTheme, nextResolvedContrast);
      setResolvedTheme(nextResolvedTheme);
      setResolvedContrast(nextResolvedContrast);
    };

    const darkMqListener = (e: MediaQueryListEvent) => {
      applyTheme(e.matches ? 'dark' : 'light', getResolvedContrast(highContrastMq, userContrast));
    };

    const contrastMqListener = () => {
      applyTheme(
        getResolvedTheme(darkThemeMq, userTheme),
        getResolvedContrast(highContrastMq, userContrast),
      );
    };

    applyTheme(
      getResolvedTheme(darkThemeMq, userTheme),
      getResolvedContrast(highContrastMq, userContrast),
    );

    if (currentTheme === 'system') {
      darkThemeMq.addEventListener('change', darkMqListener);
    }
    if (currentContrast === 'system') {
      highContrastMq.addEventListener('change', contrastMqListener);
    }

    return () => {
      if (currentTheme === 'system') {
        darkThemeMq.removeEventListener('change', darkMqListener);
      }
      if (currentContrast === 'system') {
        highContrastMq.removeEventListener('change', contrastMqListener);
      }
    };
  }, [htmlTagElement, userTheme, userContrast]);

  const setThemeState = React.useCallback(
    (theme: Theme) => {
      const darkThemeMq = getDarkThemeMq();
      const highContrastMq = getHighContrastMq();
      const nextResolvedTheme = getResolvedTheme(darkThemeMq, theme);
      const nextResolvedContrast = getResolvedContrast(highContrastMq, userContrast);
      updateThemeClass(htmlTagElement, nextResolvedTheme, nextResolvedContrast);
      setUserTheme(theme);
    },
    [htmlTagElement, setUserTheme, userContrast],
  );

  const setContrastState = React.useCallback(
    (contrast: Contrast) => {
      const darkThemeMq = getDarkThemeMq();
      const highContrastMq = getHighContrastMq();
      const nextResolvedTheme = getResolvedTheme(darkThemeMq, userTheme);
      const nextResolvedContrast = getResolvedContrast(highContrastMq, contrast);
      updateThemeClass(htmlTagElement, nextResolvedTheme, nextResolvedContrast);
      setUserContrast(contrast);
    },
    [htmlTagElement, setUserContrast, userTheme],
  );

  return {
    userTheme: getTheme(userTheme),
    setUserTheme: setThemeState,
    resolvedTheme,
    userContrast: getContrast(userContrast),
    setUserContrast: setContrastState,
    resolvedContrast,
  };
};
