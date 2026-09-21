import { useCallback, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { Alert, AlertActionCloseButton, AlertGroup } from '@patternfly/react-core';

import { ToastContext, type ToastOptions } from './ToastContext';

interface ToastEntry extends ToastOptions {
  id: number;
}

interface ToastProviderProps {
  children: ReactNode;
}

const ToastProvider = ({ children }: ToastProviderProps) => {
  const [toasts, setToasts] = useState<ToastEntry[]>([]);
  const nextId = useRef(0);

  const removeToast = useCallback((id: number) => {
    setToasts((prev) => prev.filter((toast) => toast.id !== id));
  }, []);

  const addToast = useCallback((toast: ToastOptions) => {
    const id = nextId.current++;
    setToasts((prev) => [...prev, { id, ...toast }]);
  }, []);

  return (
    <ToastContext.Provider value={{ addToast }}>
      {children}
      <AlertGroup isToast isLiveRegion>
        {toasts.map(({ id, title, description, variant, timeout }) => (
          <Alert
            key={id}
            variant={variant}
            title={title}
            // Danger toasts often carry a raw backend error message worth reading in
            // full — don't auto-dismiss those unless the caller explicitly opts in.
            timeout={timeout ?? variant !== 'danger'}
            onTimeout={() => removeToast(id)}
            actionClose={<AlertActionCloseButton onClose={() => removeToast(id)} />}
          >
            {description}
          </Alert>
        ))}
      </AlertGroup>
    </ToastContext.Provider>
  );
};

export default ToastProvider;
