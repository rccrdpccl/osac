import { createContext } from 'react';
import type { ReactNode } from 'react';
import type { AlertProps } from '@patternfly/react-core';

export interface ToastOptions {
  title: string;
  description?: ReactNode;
  variant: NonNullable<AlertProps['variant']>;
  /** Milliseconds before auto-dismiss, `true` for PatternFly's default, or `false` to disable. */
  timeout?: number | boolean;
}

export interface ToastContextValue {
  addToast: (toast: ToastOptions) => void;
}

export const ToastContext = createContext<ToastContextValue | undefined>(undefined);
