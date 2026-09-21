import {
  Button,
  EmptyState,
  EmptyStateActions,
  EmptyStateBody,
  EmptyStateFooter,
  type EmptyStateProps,
} from '@patternfly/react-core';
import LockIcon from '@patternfly/react-icons/dist/esm/icons/lock-icon';

import { useTranslation } from '../../hooks/useTranslation';

interface UnauthorizedErrorStateProps {
  headingLevel?: EmptyStateProps['headingLevel'];
}

const signInAgain = async () => {
  try {
    await fetch('/api/logout', { method: 'POST', credentials: 'include' });
  } catch {
    // Best effort before restarting login.
  }
  window.location.href = '/';
};

const UnauthorizedErrorState = ({ headingLevel = 'h2' }: UnauthorizedErrorStateProps) => {
  const { t } = useTranslation();

  return (
    <EmptyState
      icon={LockIcon}
      titleText={t('Unauthorized')}
      headingLevel={headingLevel}
      status="warning"
    >
      <EmptyStateBody>{t('You are not authorized to access this resource.')}</EmptyStateBody>
      <EmptyStateFooter>
        <EmptyStateActions>
          <Button variant="primary" onClick={() => void signInAgain()}>
            {t('Sign in again')}
          </Button>
        </EmptyStateActions>
      </EmptyStateFooter>
    </EmptyState>
  );
};

export default UnauthorizedErrorState;
