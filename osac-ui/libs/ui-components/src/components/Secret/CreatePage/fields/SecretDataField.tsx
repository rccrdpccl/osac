import {
  Button,
  FileUpload,
  FormFieldGroup,
  FormFieldGroupHeader,
  FormGroup,
  Stack,
  StackItem,
  ToggleGroup,
  ToggleGroupItem,
} from '@patternfly/react-core';
import DownloadIcon from '@patternfly/react-icons/dist/esm/icons/download-icon';
import MinusCircleIcon from '@patternfly/react-icons/dist/esm/icons/minus-circle-icon';
import PlusCircleIcon from '@patternfly/react-icons/dist/esm/icons/plus-circle-icon';
import { FieldArray, useField, useFormikContext } from 'formik';

import { useShowFieldValidationErrors } from '@osac/ui-components/components/Form/FieldValidationContext';
import {
  FormFieldHelper,
  getFormFieldHelperDescribedBy,
} from '@osac/ui-components/components/Form/FormFieldHelper';
import { InputField } from '@osac/ui-components/components/Form/InputField';

import { useTranslation } from '../../../../hooks/useTranslation';
import { getVisibleFieldError } from '../../../Form/fieldError';
import { downloadSecretBytes } from '../../utils';
import {
  SECRET_FILE_MAX_BYTES,
  type SecretDataEntry,
  type SecretTextDataEntry,
  type SecretValues,
} from '../values';

interface SecretDataEntryFieldProps {
  entry: SecretDataEntry;
  index: number;
}

const SecretDataEntryField = ({ entry, index }: SecretDataEntryFieldProps) => {
  const { t } = useTranslation();
  const { setFieldError, setFieldValue } = useFormikContext<SecretValues>();
  const entryPath = `dataEntries.${index}`;
  const fileFieldId = `secret-file-${index}`;
  const [, valueMeta, valueHelpers] = useField<string | Uint8Array | undefined>(
    `${entryPath}.value`,
  );
  const showValidationErrors = useShowFieldValidationErrors();
  const valueError = getVisibleFieldError(valueMeta, showValidationErrors);
  const valueHelperDescribedBy = getFormFieldHelperDescribedBy(fileFieldId, valueError);
  const fileValue = entry.valueType === 'file' ? entry.value : undefined;

  const setValueType = (valueType: SecretDataEntry['valueType']) => {
    void setFieldValue(
      entryPath,
      valueType === 'text'
        ? { key: entry.key, valueType, value: entry.valueType === 'text' ? entry.value : '' }
        : { key: entry.key, valueType, value: undefined },
    );
  };

  const handleFileSelected = async (file: File) => {
    if (file.size > SECRET_FILE_MAX_BYTES) {
      await valueHelpers.setTouched(true);
      setFieldError(`${entryPath}.value`, t('Secret files must not exceed 1 MiB'));
      return;
    }

    try {
      await setFieldValue(entryPath, {
        key: entry.key,
        valueType: 'file',
        value: new Uint8Array(await file.arrayBuffer()),
      });
    } catch {
      setFieldError(`${entryPath}.value`, t('Failed to read secret file'));
    }
  };

  const clearFile = async () => {
    await setFieldValue(entryPath, {
      key: entry.key,
      valueType: 'file',
      value: undefined,
    });
    await valueHelpers.setTouched(true);
  };

  return (
    <>
      <InputField
        name={`${entryPath}.key`}
        fieldId={`secret-key-${index}`}
        label={t('Key')}
        isRequired
      />

      <FormGroup label={t('Value type')} fieldId={`secret-value-type-${index}`} isRequired>
        <ToggleGroup aria-label={t('Secret value type')}>
          <ToggleGroupItem
            text={t('String')}
            isSelected={entry.valueType === 'text'}
            onChange={(_, selected) => {
              if (selected) {
                setValueType('text');
              }
            }}
          />
          <ToggleGroupItem
            text={t('File')}
            isSelected={entry.valueType === 'file'}
            onChange={(_, selected) => {
              if (selected) {
                setValueType('file');
              }
            }}
          />
        </ToggleGroup>
      </FormGroup>

      {entry.valueType === 'text' ? (
        <InputField
          name={`${entryPath}.value`}
          fieldId={`secret-value-${index}`}
          label={t('Value')}
          isRequired
          rows={4}
          multiline
        />
      ) : (
        <FormGroup label={t('Value')} fieldId={fileFieldId} isRequired>
          <Stack hasGutter>
            <FileUpload
              id={fileFieldId}
              filename={fileValue ? entry.key : ''}
              browseButtonText={t('Choose file')}
              clearButtonText={t('Clear file')}
              filenameAriaLabel={t('Selected secret file')}
              filenamePlaceholder={t('No file selected')}
              validated={valueError ? 'error' : 'default'}
              aria-invalid={valueError ? true : undefined}
              aria-describedby={valueHelperDescribedBy}
              browseButtonAriaDescribedby={valueHelperDescribedBy}
              onFileInputChange={(_event, file) => {
                void handleFileSelected(file);
              }}
              onClearClick={() => void clearFile()}
            />
            {fileValue && (
              <Button
                variant="link"
                icon={<DownloadIcon />}
                onClick={() => downloadSecretBytes(fileValue, entry.key)}
              >
                {t('Download current value')}
              </Button>
            )}
          </Stack>
          <FormFieldHelper error={valueError} fieldId={fileFieldId} />
        </FormGroup>
      )}
    </>
  );
};

const SecretDataField = () => {
  const { t } = useTranslation();
  const { values } = useFormikContext<SecretValues>();

  return (
    <FormGroup label={t('Secret data')} fieldId="secret-data" isRequired>
      <FieldArray name="dataEntries">
        {(arrayHelpers) => (
          <Stack hasGutter>
            {values.dataEntries.map((entry, index) => {
              return (
                <StackItem key={index}>
                  <FormFieldGroup
                    header={
                      <FormFieldGroupHeader
                        titleText={{
                          text: t('Secret entry {{number}}', { number: index + 1 }),
                          id: `secret-entry-group-${index}`,
                        }}
                        actions={
                          <Button
                            variant="plain"
                            aria-label={t('Remove secret entry')}
                            onClick={() => arrayHelpers.remove(index)}
                            isDisabled={values.dataEntries.length === 1}
                            icon={<MinusCircleIcon />}
                          />
                        }
                      />
                    }
                  >
                    <SecretDataEntryField entry={entry} index={index} />
                  </FormFieldGroup>
                </StackItem>
              );
            })}
            <StackItem>
              <Button
                variant="link"
                icon={<PlusCircleIcon />}
                onClick={() =>
                  arrayHelpers.push<SecretTextDataEntry>({ key: '', valueType: 'text', value: '' })
                }
              >
                {t('Add secret entry')}
              </Button>
            </StackItem>
          </Stack>
        )}
      </FieldArray>
    </FormGroup>
  );
};

export default SecretDataField;
