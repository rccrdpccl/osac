import { ResourceDetailsPageError } from './ResourceDetailsPageError';
import { ResourceDetailsPageLoading } from './ResourceDetailsPageLoading';

interface ResourceDetailsPageProps {
  isLoading: boolean;
  error: unknown;
  found: boolean;
  refetch: VoidFunction;
  parentTo: string;
  parentLabel: string;
  tabLabels?: string[];
  cardCount?: number;
  resourceLabel?: string;
}

const ResourceDetailsPage = ({
  isLoading,
  error,
  found,
  refetch,
  parentTo,
  parentLabel,
  tabLabels,
  cardCount,
  resourceLabel,
  children,
}: React.PropsWithChildren<ResourceDetailsPageProps>) => {
  if (isLoading) {
    return (
      <ResourceDetailsPageLoading
        parentTo={parentTo}
        parentLabel={parentLabel}
        tabLabels={tabLabels}
        cardCount={cardCount}
      />
    );
  }

  if (error) {
    return (
      <ResourceDetailsPageError
        parentTo={parentTo}
        parentLabel={parentLabel}
        resourceLabel={resourceLabel}
        error={error}
        onRetry={() => void refetch()}
      />
    );
  }

  if (!found) {
    return (
      <ResourceDetailsPageError
        parentTo={parentTo}
        parentLabel={parentLabel}
        resourceLabel={resourceLabel}
        variant="not-found"
      />
    );
  }

  return children;
};

export default ResourceDetailsPage;
