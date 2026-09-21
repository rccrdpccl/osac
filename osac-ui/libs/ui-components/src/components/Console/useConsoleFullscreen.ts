import { useCallback, useEffect, useRef, useState } from 'react';

type FullscreenDocument = Document & {
  webkitExitFullscreen?: () => Promise<void>;
  webkitFullscreenElement?: Element | null;
};

type FullscreenElement = HTMLElement & {
  webkitRequestFullscreen?: () => Promise<void>;
};

const getFullscreenElement = () => {
  const doc = document as FullscreenDocument;
  return document.fullscreenElement ?? doc.webkitFullscreenElement ?? null;
};

const notifyViewportResize = () => {
  window.dispatchEvent(new Event('resize'));
};

export const useConsoleFullscreen = () => {
  const containerRef = useRef<HTMLDivElement>(null);
  const [isFullscreen, setIsFullscreen] = useState(false);

  useEffect(() => {
    const onFullscreenChange = () => {
      const active = getFullscreenElement() === containerRef.current;
      setIsFullscreen(active);
      notifyViewportResize();
    };

    document.addEventListener('fullscreenchange', onFullscreenChange);
    document.addEventListener('webkitfullscreenchange', onFullscreenChange);

    return () => {
      document.removeEventListener('fullscreenchange', onFullscreenChange);
      document.removeEventListener('webkitfullscreenchange', onFullscreenChange);
    };
  }, []);

  const leaveFullscreen = useCallback(async () => {
    if (getFullscreenElement() !== containerRef.current) {
      return;
    }

    const doc = document as FullscreenDocument;
    const exit =
      document.exitFullscreen?.bind(document) ?? doc.webkitExitFullscreen?.bind(document);
    try {
      await exit?.();
    } catch {
      // Browsers can reject exitFullscreen (e.g. already left, or not user-initiated).
      // Ignore — fullscreenchange listener keeps isFullscreen in sync regardless.
    }
  }, []);

  const toggleFullscreen = useCallback(async () => {
    const container = containerRef.current;
    if (!container) {
      return;
    }

    if (getFullscreenElement() === container) {
      await leaveFullscreen();
      return;
    }

    const request =
      container.requestFullscreen?.bind(container) ??
      (container as FullscreenElement).webkitRequestFullscreen?.bind(container);
    try {
      await request?.();
    } catch {
      // Browsers reject fullscreen when the call is not from a direct user gesture
      // (or the permission was denied). Ignore — console remains usable windowed.
    }
  }, [leaveFullscreen]);

  return { containerRef, isFullscreen, leaveFullscreen, toggleFullscreen };
};
