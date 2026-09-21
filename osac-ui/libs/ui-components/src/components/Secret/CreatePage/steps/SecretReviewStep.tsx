import {
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
  Stack,
  StackItem,
  Title,
} from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import { useTranslation } from '../../../../hooks/useTranslation';
import type { SecretValues } from '../values';

const SecretReviewStep = () => {
  const { t } = useTranslation();
  const { values } = useFormikContext<SecretValues>();

  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Review')}
        </Title>
      </StackItem>
      <StackItem>
        <DescriptionList isHorizontal isCompact aria-label={t('Review')}>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Name')}</DescriptionListTerm>
            <DescriptionListDescription>{values.metadata.name}</DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Project')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.metadata.project || t('Default')}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Entries')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.dataEntries.map((e) => e.key).join(', ')}
            </DescriptionListDescription>
          </DescriptionListGroup>
        </DescriptionList>
      </StackItem>
    </Stack>
  );
};

export default SecretReviewStep;
