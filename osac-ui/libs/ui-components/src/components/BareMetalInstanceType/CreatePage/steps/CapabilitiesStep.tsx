import { Stack, StackItem, Title } from '@patternfly/react-core';

import { useTranslation } from '../../../../hooks/useTranslation';
import { KeyValueMapField } from '../../../Form/KeyValueMapField';
import OsacForm from '../../../Form/OsacForm';

const CapabilitiesStep = () => {
  const { t } = useTranslation();
  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Capabilities')}
        </Title>
      </StackItem>
      <StackItem>
        <OsacForm>
          <KeyValueMapField
            name="spec.capabilities"
            fieldId="baremetal-instance-type-capabilities"
            label={t('Capabilities')}
            addLabel={t('Add capability')}
            removeLabel={t('Remove capability')}
            helperText={t('Freeform capability tags for additional hardware metadata.')}
          />
        </OsacForm>
      </StackItem>
    </Stack>
  );
};

export default CapabilitiesStep;
