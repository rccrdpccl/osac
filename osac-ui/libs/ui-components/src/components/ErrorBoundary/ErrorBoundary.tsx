import React from 'react';
import { Alert } from '@patternfly/react-core';

import { getErrorMessage } from '../../utils/error';

interface State {
  hasError: boolean;
  error: Error;
  info: React.ErrorInfo;
}

class ErrorBoundary extends React.Component<React.PropsWithChildren, State> {
  state = {
    hasError: false,
    error: { message: '', stack: '' } as Error,
    info: { componentStack: '' },
  };

  static getDerivedStateFromError = (/* error */) => {
    return { hasError: true };
  };

  componentDidCatch = (error: Error, info: React.ErrorInfo) => {
    this.setState({ error, info });
  };

  render() {
    const { hasError, error } = this.state;
    const { children } = this.props;
    if (!hasError && !children) {
      return null;
    }

    return hasError ? (
      <Alert variant="danger" title="Unexpected error occurred" isInline>
        Please reload the page and try again
        <details>{getErrorMessage(error)}</details>
      </Alert>
    ) : (
      children
    );
  }
}

export default ErrorBoundary;
