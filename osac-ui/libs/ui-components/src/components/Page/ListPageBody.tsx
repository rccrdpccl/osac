import * as React from 'react';
import { Bullseye, Spinner } from '@patternfly/react-core';

import ErrorBoundary from '../ErrorBoundary/ErrorBoundary';
import QueryErrorState from '../Resource/QueryErrorState';

type ListPageBodyProps = {
  isLoading: boolean;
  error?: unknown;
};

const ListPageBody = ({
  isLoading,
  error,
  children,
}: React.PropsWithChildren<ListPageBodyProps>) => {
  if (isLoading) {
    return (
      <Bullseye>
        <Spinner />
      </Bullseye>
    );
  }
  if (error) {
    return <QueryErrorState error={error} mode="page" />;
  }

  return <ErrorBoundary>{children}</ErrorBoundary>;
};

export default ListPageBody;
