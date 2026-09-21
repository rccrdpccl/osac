import { EmptyState, EmptyStateBody } from '@patternfly/react-core';

import { useTranslation } from '@osac/ui-components/hooks/useTranslation';

export const StoragePlaceholder = ({ title }: { title: string }) => {
  const { t } = useTranslation();

  return (
    <EmptyState titleText={title} headingLevel="h2">
      <EmptyStateBody>{t('This feature is coming soon.')}</EmptyStateBody>
    </EmptyState>
  );
};
