import { Stack, StackItem, Title } from '@patternfly/react-core';

import { useTranslation } from '../../../../hooks/useTranslation';
import OsacForm from '../../../Form/OsacForm';
import BareMetalDisksField from '../fields/BareMetalDisksField';

const DisksStep = () => {
  const { t } = useTranslation();
  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Disks')}
        </Title>
      </StackItem>
      <StackItem>
        <OsacForm>
          <BareMetalDisksField />
        </OsacForm>
      </StackItem>
    </Stack>
  );
};

export default DisksStep;
