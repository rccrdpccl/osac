import { Stack, StackItem, Title } from '@patternfly/react-core';

import { useTranslation } from '../../../../hooks/useTranslation';
import OsacForm from '../../../Form/OsacForm';
import BareMetalAcceleratorsField from '../fields/BareMetalAcceleratorsField';

const AcceleratorsStep = () => {
  const { t } = useTranslation();
  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Accelerators')}
        </Title>
      </StackItem>
      <StackItem>
        <OsacForm>
          <BareMetalAcceleratorsField />
        </OsacForm>
      </StackItem>
    </Stack>
  );
};

export default AcceleratorsStep;
