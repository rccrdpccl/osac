import { FormSection, Stack, StackItem, Title } from '@patternfly/react-core';

import { useTranslation } from '../../../../hooks/useTranslation';
import { InputField } from '../../../Form/InputField';
import NumberField from '../../../Form/NumberField';
import OsacForm from '../../../Form/OsacForm';

const CpuMemoryStep = () => {
  const { t } = useTranslation();
  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('CPU & Memory')}
        </Title>
      </StackItem>
      <StackItem>
        <OsacForm>
          <FormSection title={t('CPU')}>
            <NumberField
              name="spec.cpu.cores"
              label={t('Cores')}
              fieldId="baremetal-instance-type-cpu-cores"
              isRequired
              min={1}
              step={1}
            />
            <InputField
              name="spec.cpu.architecture"
              label={t('Architecture')}
              fieldId="baremetal-instance-type-cpu-architecture"
              isRequired
              placeholder={t('e.g. x86_64, aarch64')}
            />
            <InputField
              name="spec.cpu.model"
              label={t('Model')}
              fieldId="baremetal-instance-type-cpu-model"
            />
            <NumberField
              name="spec.cpu.threadsPerCore"
              label={t('Threads per core')}
              fieldId="baremetal-instance-type-cpu-threads-per-core"
              isRequired
              min={1}
              step={1}
            />
          </FormSection>
          <FormSection title={t('Memory')}>
            <NumberField
              name="spec.memory.totalGb"
              label={t('Total (GB)')}
              fieldId="baremetal-instance-type-memory-total"
              isRequired
              min={1}
              step={1}
              type="bigint"
            />
            <InputField
              name="spec.memory.type"
              label={t('Type')}
              fieldId="baremetal-instance-type-memory-type"
              placeholder={t('e.g. DDR4, DDR5')}
            />
          </FormSection>
        </OsacForm>
      </StackItem>
    </Stack>
  );
};

export default CpuMemoryStep;
