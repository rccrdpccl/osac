import { useEffect, useRef } from 'react';
import { Stack, StackItem } from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import type { BareMetalInstanceCatalogItem } from '@osac/types';

import { BareMetalNetworkAttachmentsField } from './BareMetalNetworkAttachmentsField';
import type { BareMetalInstanceWizardValues } from './fields';
import { useTranslation } from '../../../../../hooks/useTranslation';
import { CheckboxField } from '../../../../Form/CheckboxField';
import OsacForm from '../../../../Form/OsacForm';
import { useWizardValidation } from '../../WizardValidationContext';

interface Props {
  catalogItem: BareMetalInstanceCatalogItem | null;
}

const clearAttachmentFieldTouched = (
  setFieldTouched: (
    field: string,
    touched?: boolean,
    shouldValidate?: boolean,
  ) => Promise<void | Record<string, unknown>>,
  attachmentCount: number,
) => {
  void setFieldTouched('spec.networking.attachments', false, false);
  for (let index = 0; index < attachmentCount; index += 1) {
    void setFieldTouched(`spec.networking.attachments.${index}.virtualNetwork`, false, false);
    void setFieldTouched(`spec.networking.attachments.${index}.subnet`, false, false);
    void setFieldTouched(`spec.networking.attachments.${index}.securityGroups`, false, false);
  }
};

export const BareMetalNetworkingStep = ({ catalogItem }: Props) => {
  const { t } = useTranslation();
  const { clearValidationAlert } = useWizardValidation();
  const { values, setFieldTouched, validateForm } =
    useFormikContext<BareMetalInstanceWizardValues>();
  const previousUseDefaultsRef = useRef(values.spec.networking.useDefaults);

  const useDefaults = values.spec.networking.useDefaults;
  const attachExternalIp = values.spec.networking.attachExternalIp;
  useEffect(() => {
    const wasCustom = previousUseDefaultsRef.current === false;
    previousUseDefaultsRef.current = useDefaults;

    if (!useDefaults || !wasCustom) {
      return;
    }

    clearAttachmentFieldTouched(setFieldTouched, values.spec.networking.attachments.length);
    clearValidationAlert();
    void validateForm();
  }, [
    clearValidationAlert,
    setFieldTouched,
    useDefaults,
    validateForm,
    values.spec.networking.attachments.length,
  ]);

  if (!catalogItem) {
    return null;
  }

  return (
    <Stack hasGutter>
      <StackItem>
        <OsacForm>
          <CheckboxField
            name="spec.networking.useDefaults"
            label={t('Use tenant default network')}
            fieldId="bm-use-defaults"
          />
        </OsacForm>
      </StackItem>

      {!useDefaults && (
        <StackItem>
          <BareMetalNetworkAttachmentsField />
        </StackItem>
      )}

      <StackItem>
        <OsacForm>
          <CheckboxField
            name="spec.networking.attachExternalIp"
            label={t('Attach external IP at creation')}
            fieldId="bm-attach-external-ip"
          />
          {attachExternalIp && (
            <p>
              {t(
                "The system will auto-create an ExternalIP and ExternalIPAttachment bound to the server's primary attachment. Auto-created resources are deleted when the instance is deleted.",
              )}
            </p>
          )}
        </OsacForm>
      </StackItem>
    </Stack>
  );
};
