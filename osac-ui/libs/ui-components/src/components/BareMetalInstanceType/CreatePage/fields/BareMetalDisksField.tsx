import {
  Button,
  FormFieldGroup,
  FormFieldGroupHeader,
  Stack,
  StackItem,
} from '@patternfly/react-core';
import MinusCircleIcon from '@patternfly/react-icons/dist/esm/icons/minus-circle-icon';
import PlusCircleIcon from '@patternfly/react-icons/dist/esm/icons/plus-circle-icon';
import { FieldArray, useFormikContext } from 'formik';

import { useTranslation } from '../../../../hooks/useTranslation';
import { InputField } from '../../../Form/InputField';
import NumberField from '../../../Form/NumberField';
import { type BareMetalInstanceTypeFormValues, emptyDiskValue } from '../values';

const BareMetalDisksField = () => {
  const { t } = useTranslation();
  const { values } = useFormikContext<BareMetalInstanceTypeFormValues>();
  const disks = values.spec.disks;

  return (
    <FieldArray name="spec.disks">
      {(helpers) => (
        <Stack hasGutter>
          {disks.length === 0 && <StackItem>{t('No disks added.')}</StackItem>}
          {disks.map((_, index) => (
            <StackItem key={index}>
              <FormFieldGroup
                header={
                  <FormFieldGroupHeader
                    titleText={{
                      text: t('Disk {{number}}', { number: index + 1 }),
                      id: `baremetal-disk-group-${index}`,
                    }}
                    actions={
                      <Button
                        variant="plain"
                        aria-label={t('Remove disk')}
                        onClick={() => helpers.remove(index)}
                        icon={<MinusCircleIcon />}
                      />
                    }
                  />
                }
              >
                <InputField
                  name={`spec.disks.${index}.type`}
                  label={t('Type')}
                  fieldId={`baremetal-disk-${index}-type`}
                  isRequired
                  placeholder={t('e.g. SSD, NVMe, HDD')}
                />
                <NumberField
                  name={`spec.disks.${index}.capacityGb`}
                  label={t('Capacity (GB)')}
                  fieldId={`baremetal-disk-${index}-capacity`}
                  isRequired
                  min={1}
                  step={1}
                  type="bigint"
                />
                <InputField
                  name={`spec.disks.${index}.interface`}
                  label={t('Interface')}
                  fieldId={`baremetal-disk-${index}-interface`}
                  isRequired
                  placeholder={t('e.g. SATA, NVMe, SAS')}
                />
              </FormFieldGroup>
            </StackItem>
          ))}
          <StackItem>
            <Button
              variant="link"
              icon={<PlusCircleIcon />}
              onClick={() => helpers.push(emptyDiskValue())}
            >
              {t('Add disk')}
            </Button>
          </StackItem>
        </Stack>
      )}
    </FieldArray>
  );
};

export default BareMetalDisksField;
