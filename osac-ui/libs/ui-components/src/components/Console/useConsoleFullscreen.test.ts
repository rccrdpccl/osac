import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { useConsoleFullscreen } from './useConsoleFullscreen';

describe('useConsoleFullscreen', () => {
  beforeEach(() => {
    vi.stubGlobal(
      'ResizeObserver',
      class ResizeObserver {
        observe = vi.fn();

        disconnect = vi.fn();

        constructor(_callback: ResizeObserverCallback) {}
      },
    );
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    // vi.restoreAllMocks() only restores spies — it doesn't undo the own-property
    // overrides tests below install directly on `document`, which would otherwise
    // leak into later tests in this file.
    delete (document as { fullscreenElement?: Element | null }).fullscreenElement;
    delete (document as { exitFullscreen?: () => Promise<void> }).exitFullscreen;
  });

  it('enters and exits fullscreen on the container element', async () => {
    const requestFullscreen = vi.fn().mockResolvedValue(undefined);
    const exitFullscreen = vi.fn().mockResolvedValue(undefined);
    const resizeListener = vi.fn();

    Object.defineProperty(document, 'fullscreenElement', {
      configurable: true,
      writable: true,
      value: null,
    });
    document.exitFullscreen = exitFullscreen;

    window.addEventListener('resize', resizeListener);

    const { result } = renderHook(() => useConsoleFullscreen());
    const container = document.createElement('div');
    container.requestFullscreen = requestFullscreen;
    result.current.containerRef.current = container;

    await act(async () => {
      await result.current.toggleFullscreen();
    });

    expect(requestFullscreen).toHaveBeenCalledTimes(1);

    Object.defineProperty(document, 'fullscreenElement', {
      configurable: true,
      writable: true,
      value: container,
    });

    act(() => {
      document.dispatchEvent(new Event('fullscreenchange'));
    });

    expect(result.current.isFullscreen).toBe(true);
    expect(resizeListener).toHaveBeenCalled();

    await act(async () => {
      await result.current.toggleFullscreen();
    });

    expect(exitFullscreen).toHaveBeenCalledTimes(1);
  });

  it('leaveFullscreen is a no-op when the container is not fullscreen', async () => {
    const exitFullscreen = vi.fn().mockResolvedValue(undefined);
    document.exitFullscreen = exitFullscreen;

    const { result } = renderHook(() => useConsoleFullscreen());
    const container = document.createElement('div');
    result.current.containerRef.current = container;

    await act(async () => {
      await result.current.leaveFullscreen();
    });

    expect(exitFullscreen).not.toHaveBeenCalled();
  });
});
