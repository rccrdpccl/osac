import { type EmptyStateProps, PageSection } from '@patternfly/react-core';

import QueryErrorState, { type QueryErrorStateProps } from './QueryErrorState';

type QueryErrorPageProps = Omit<QueryErrorStateProps, 'mode'> & {
  headingLevel?: EmptyStateProps['headingLevel'];
};

const QueryErrorPage = ({ headingLevel = 'h1', ...props }: QueryErrorPageProps) => (
  <PageSection hasBodyWrapper={false} isFilled>
    <QueryErrorState {...props} mode="page" headingLevel={headingLevel} />
  </PageSection>
);

export default QueryErrorPage;
