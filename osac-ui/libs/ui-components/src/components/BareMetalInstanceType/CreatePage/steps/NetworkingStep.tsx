import { Stack, StackItem, Title } from '@patternfly/react-core';

import { useTranslation } from '../../../../hooks/useTranslation';
import OsacForm from '../../../Form/OsacForm';
import BareMetalNetworkPortsField from '../fields/BareMetalNetworkPortsField';

const NetworkingStep = () => {
  const { t } = useTranslation();
  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Networking')}
        </Title>
      </StackItem>
      <StackItem>
        <OsacForm>
          <BareMetalNetworkPortsField />
        </OsacForm>
      </StackItem>
    </Stack>
  );
};

export default NetworkingStep;
