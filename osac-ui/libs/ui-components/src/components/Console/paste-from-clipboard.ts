import type { VncRfbInstance } from './novnc-rfb';

const SHIFT_LEFT = 'ShiftLeft';
const XK_SHIFT_L = 0xffe1;
const XK_RETURN = 0xff0d;
const XK_TAB = 0xff09;
const XK_BACKSPACE = 0xff08;
const KEYSTROKE_DELAY_MS = 10;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

interface KeyMapping {
  keysym: number;
  code: string;
  shift: boolean;
}

const UNSHIFTED_CHAR_TO_CODE: Record<string, string> = {
  '`': 'Backquote',
  '-': 'Minus',
  '=': 'Equal',
  '[': 'BracketLeft',
  ']': 'BracketRight',
  '\\': 'Backslash',
  ';': 'Semicolon',
  "'": 'Quote',
  ',': 'Comma',
  '.': 'Period',
  '/': 'Slash',
  ' ': 'Space',
};

const SHIFTED_CHAR_TO_CODE: Record<string, string> = {
  '~': 'Backquote',
  '!': 'Digit1',
  '@': 'Digit2',
  '#': 'Digit3',
  $: 'Digit4',
  '%': 'Digit5',
  '^': 'Digit6',
  '&': 'Digit7',
  '*': 'Digit8',
  '(': 'Digit9',
  ')': 'Digit0',
  _: 'Minus',
  '+': 'Equal',
  '{': 'BracketLeft',
  '}': 'BracketRight',
  '|': 'Backslash',
  ':': 'Semicolon',
  '"': 'Quote',
  '<': 'Comma',
  '>': 'Period',
  '?': 'Slash',
};

const resolveKeyMapping = (char: string): KeyMapping | null => {
  if (char === '\n' || char === '\r') {
    return { keysym: XK_RETURN, code: 'Enter', shift: false };
  }
  if (char === '\t') {
    return { keysym: XK_TAB, code: 'Tab', shift: false };
  }
  if (char === '\b') {
    return { keysym: XK_BACKSPACE, code: 'Backspace', shift: false };
  }

  const codePoint = char.codePointAt(0);
  if (codePoint === undefined) {
    return null;
  }

  if (codePoint >= 0x61 && codePoint <= 0x7a) {
    const letter = char.toUpperCase();
    return { keysym: codePoint, code: `Key${letter}`, shift: false };
  }
  if (codePoint >= 0x41 && codePoint <= 0x5a) {
    return { keysym: codePoint, code: `Key${char}`, shift: true };
  }
  if (codePoint >= 0x30 && codePoint <= 0x39) {
    return { keysym: codePoint, code: `Digit${char}`, shift: false };
  }

  const unshifted = UNSHIFTED_CHAR_TO_CODE[char];
  if (unshifted) {
    return { keysym: codePoint, code: unshifted, shift: false };
  }

  const shifted = SHIFTED_CHAR_TO_CODE[char];
  if (shifted) {
    return { keysym: codePoint, code: shifted, shift: true };
  }

  // For unmapped printable ASCII, send keysym only (no scan code)
  if (codePoint >= 0x20 && codePoint <= 0x7e) {
    return { keysym: codePoint, code: '', shift: false };
  }

  return null;
};

export const pasteFromClipboard = async (
  rfb: VncRfbInstance,
  isActive: () => boolean = () => true,
): Promise<void> => {
  let text: string;
  try {
    text = await navigator.clipboard.readText();
  } catch {
    return;
  }

  if (!text) {
    return;
  }

  for (const char of text) {
    if (!isActive()) {
      return;
    }

    const mapping = resolveKeyMapping(char);
    if (!mapping) {
      continue;
    }

    if (mapping.shift) {
      rfb.sendKey(XK_SHIFT_L, SHIFT_LEFT, true);
    }
    rfb.sendKey(mapping.keysym, mapping.code, true);
    rfb.sendKey(mapping.keysym, mapping.code, false);
    if (mapping.shift) {
      rfb.sendKey(XK_SHIFT_L, SHIFT_LEFT, false);
    }

    await sleep(KEYSTROKE_DELAY_MS);
  }

  if (isActive()) {
    rfb.focus();
  }
};
