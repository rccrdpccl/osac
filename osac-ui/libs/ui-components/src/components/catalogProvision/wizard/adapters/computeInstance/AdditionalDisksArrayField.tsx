import {
  Button,
  FormFieldGroup,
  FormFieldGroupHeader,
  Stack,
  StackItem,
} from '@patternfly/react-core';
import MinusCircleIcon from '@patternfly/react-icons/dist/esm/icons/minus-circle-icon';
import PlusCircleIcon from '@patternfly/react-icons/dist/esm/icons/plus-circle-icon';
import { useFormikContext } from 'formik';

import type { ComputeInstanceWizardValues } from './fields';
import { useTranslation } from '../../../../../hooks/useTranslation';
import { InputField } from '../../../../Form/InputField';
import { emptyResourceSelectValue } from '../../../../Form/resourceSelectValue';
import { StorageTierSelectField } from '../../../../Form/StorageTierSelectField';

/** Same mechanism as ClusterNodeSetsArrayField: every row is always live and editable; Add appends a row, Remove deletes one. No separate editor/confirm/cancel state. */
export const AdditionalDisksArrayField = () => {
  const { t } = useTranslation();
  const { values, setFieldValue } = useFormikContext<ComputeInstanceWizardValues>();
  const disks = values.spec.additionalDisks;

  const addDisk = () => {
    void setFieldValue('spec.additionalDisks', [
      ...disks,
      { sizeGib: '30', storageTier: emptyResourceSelectValue() },
    ]);
  };

  const removeDisk = (index: number) => {
    void setFieldValue(
      'spec.additionalDisks',
      disks.filter((_, i) => i !== index),
    );
  };

  return (
    <Stack hasGutter>
      {disks.length === 0 ? <StackItem>{t('No additional disks added.')}</StackItem> : null}
      {disks.map((_, index) => (
        <StackItem key={index}>
          <FormFieldGroup
            header={
              <FormFieldGroupHeader
                titleText={{
                  text: t('Disk {{number}}', { number: index + 1 }),
                  id: `vm-additional-disk-group-${index}`,
                }}
                actions={
                  <Button
                    variant="plain"
                    aria-label={t('Remove disk')}
                    onClick={() => removeDisk(index)}
                    icon={<MinusCircleIcon />}
                  />
                }
              />
            }
          >
            <InputField
              name={`spec.additionalDisks.${index}.sizeGib`}
              label={t('Size (GiB)')}
              fieldId={`vm-additional-disk-${index}-size`}
              type="number"
              isRequired
              min={1}
              max={16384}
              step={1}
              helperText={t('Size in GiB')}
            />
            <StorageTierSelectField
              name={`spec.additionalDisks.${index}.storageTier`}
              label={t('Storage tier')}
              fieldId={`vm-additional-disk-${index}-storage-tier`}
              isRequired
            />
          </FormFieldGroup>
        </StackItem>
      ))}
      <StackItem>
        <Button variant="link" icon={<PlusCircleIcon />} onClick={addDisk}>
          {t('Add disk')}
        </Button>
      </StackItem>
    </Stack>
  );
};
