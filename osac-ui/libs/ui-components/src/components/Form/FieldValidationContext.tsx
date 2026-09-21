import type { ReactNode } from 'react';
import { createContext, useContext, useState } from 'react';

interface FieldValidationContextValue {
  showErrors: boolean;
  setShowErrors: (show: boolean) => void;
}

const FieldValidationContext = createContext<FieldValidationContextValue>({
  showErrors: false,
  setShowErrors: () => undefined,
});

export const useFieldValidation = () => useContext(FieldValidationContext);

interface FieldValidationProviderProps {
  children: ReactNode;
  showErrors?: boolean;
}

export const FieldValidationProvider = ({
  children,
  showErrors: externalShowErrors,
}: FieldValidationProviderProps) => {
  const [internalShowErrors, setShowErrors] = useState(false);
  const showErrors = externalShowErrors ?? internalShowErrors;
  return (
    <FieldValidationContext.Provider value={{ showErrors, setShowErrors }}>
      {children}
    </FieldValidationContext.Provider>
  );
};
export const useShowFieldValidationErrors = (): boolean =>
  useContext(FieldValidationContext).showErrors;
