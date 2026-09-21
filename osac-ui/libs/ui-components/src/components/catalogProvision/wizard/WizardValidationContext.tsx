import { type ReactNode, createContext, useContext } from 'react';

interface WizardValidationContextValue {
  clearValidationAlert: () => void;
}

const WizardValidationContext = createContext<WizardValidationContextValue>({
  clearValidationAlert: () => undefined,
});

export const useWizardValidation = (): WizardValidationContextValue =>
  useContext(WizardValidationContext);

interface WizardValidationProviderProps {
  children: ReactNode;
  clearValidationAlert: () => void;
}

export const WizardValidationProvider = ({
  children,
  clearValidationAlert,
}: WizardValidationProviderProps) => (
  <WizardValidationContext.Provider value={{ clearValidationAlert }}>
    {children}
  </WizardValidationContext.Provider>
);
