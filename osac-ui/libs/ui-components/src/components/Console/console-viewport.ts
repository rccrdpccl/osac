/** Shared viewport sizing for embedded serial/VNC console viewers. */
export const CONSOLE_VIEWPORT_CLASS_NAME = 'vm-console-viewport';

/** Wrapper targeted by the browser Fullscreen API. */
export const CONSOLE_FULLSCREEN_CONTAINER_CLASS_NAME = 'vm-console-fullscreen-container';

/** Inner Stack that fills the fullscreen container under the toolbar. */
export const CONSOLE_FULLSCREEN_STACK_CLASS_NAME = 'vm-console-fullscreen-stack';

/** Positions the connecting overlay on top of the (still initializing) viewer. */
export const CONSOLE_STACK_CLASS_NAME = 'vm-console-stack';

/** Empty-state overlay shown until the viewer reports it has connected. */
export const CONSOLE_CONNECTING_OVERLAY_CLASS_NAME = 'vm-console-connecting-overlay';

/** Keeps the viewer mounted (so it can connect) without painting it until ready. */
export const CONSOLE_VIEWPORT_HIDDEN_CLASS_NAME = 'vm-console-viewport--hidden';
