import {
  Button,
  EmptyState,
  EmptyStateActions,
  EmptyStateBody,
  EmptyStateFooter,
  type EmptyStateProps,
} from '@patternfly/react-core';
import ExclamationTriangleIcon from '@patternfly/react-icons/dist/esm/icons/exclamation-triangle-icon';

import UnauthorizedErrorState from './UnauthorizedErrorState';
import { getErrorMessage } from '../../utils/error';
import { isUnauthorizedError } from '../../utils/unauthorizedError';

export interface QueryErrorAction {
  label: string;
  onClick: () => void;
  variant?: 'primary' | 'link';
}

export interface QueryErrorStateProps {
  error: unknown;
  mode?: 'inline' | 'page';
  headingLevel?: EmptyStateProps['headingLevel'];
  title?: string;
  body?: string;
  status?: EmptyStateProps['status'];
  icon?: EmptyStateProps['icon'];
  onRetry?: () => void;
  secondaryAction?: QueryErrorAction;
}

const QueryErrorState = ({
  error,
  mode = 'inline',
  headingLevel = mode === 'page' ? 'h1' : 'h2',
  title = 'An error occurred',
  body,
  status = 'danger',
  icon = ExclamationTriangleIcon,
  onRetry,
  secondaryAction,
}: QueryErrorStateProps) => {
  if (error && isUnauthorizedError(error)) {
    return <UnauthorizedErrorState headingLevel={headingLevel} />;
  }

  const message = body ?? (error ? getErrorMessage(error) : '');

  return (
    <EmptyState icon={icon} titleText={title} headingLevel={headingLevel} status={status}>
      <EmptyStateBody>{message}</EmptyStateBody>
      {(onRetry || secondaryAction) && (
        <EmptyStateFooter>
          <EmptyStateActions>
            {onRetry ? (
              <Button variant="primary" onClick={onRetry}>
                Retry
              </Button>
            ) : null}
            {secondaryAction ? (
              <Button
                variant={onRetry ? (secondaryAction.variant ?? 'link') : 'primary'}
                onClick={secondaryAction.onClick}
              >
                {secondaryAction.label}
              </Button>
            ) : null}
          </EmptyStateActions>
        </EmptyStateFooter>
      )}
    </EmptyState>
  );
};

export default QueryErrorState;
