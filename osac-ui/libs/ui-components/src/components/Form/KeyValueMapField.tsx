import {
  Button,
  FormGroup,
  HelperText,
  HelperTextItem,
  Split,
  SplitItem,
  Stack,
  StackItem,
  TextInput,
} from '@patternfly/react-core';
import MinusCircleIcon from '@patternfly/react-icons/dist/esm/icons/minus-circle-icon';
import PlusCircleIcon from '@patternfly/react-icons/dist/esm/icons/plus-circle-icon';
import { FieldArray, getIn, useField, useFormikContext } from 'formik';

import { getVisibleFieldError } from './fieldError';
import { useShowFieldValidationErrors } from './FieldValidationContext';
import { FormFieldHelper, getFormFieldHelperDescribedBy } from './FormFieldHelper';
import { useTranslation } from '../../hooks/useTranslation';

export interface KeyValuePair {
  key: string;
  value: string;
}

interface KeyValueMapFieldProps {
  /** Formik path of the array-of-pairs field. */
  name: string;
  /** Base id used to derive per-row element ids. */
  fieldId: string;
  /** Group label. */
  label: string;
  isRequired?: boolean;
  /** Label for the "add pair" action. */
  addLabel: string;
  /** Accessible label for each row's remove action. */
  removeLabel: string;
  /** Placeholder for the key input (also the base of each input's accessible name). */
  keyLabel?: string;
  /** Placeholder for the value input. */
  valueLabel?: string;
  helperText?: string;
}

/**
 * Key/value map editor backed by an array of `{ key, value }` pairs. Add appends an
 * empty pair, each row's Remove deletes it, and array-level Yup errors (e.g. a
 * required minimum) surface once the field is touched or the form is submitted.
 */
export const KeyValueMapField = ({
  name,
  fieldId,
  label,
  isRequired = false,
  addLabel,
  removeLabel,
  keyLabel,
  valueLabel,
  helperText,
}: KeyValueMapFieldProps) => {
  const { t } = useTranslation();
  const { errors, submitCount, touched } = useFormikContext();
  const [field, meta] = useField<KeyValuePair[]>(name);
  const showValidationErrors = useShowFieldValidationErrors();
  const pairs = field.value ?? [];
  const keyText = keyLabel ?? t('Key');
  const valueText = valueLabel ?? t('Value');
  const error =
    typeof meta.error === 'string'
      ? getVisibleFieldError(meta, showValidationErrors || submitCount > 0)
      : undefined;
  const getPairFieldError = (index: number, fieldName: keyof KeyValuePair) => {
    const path = `${name}.${index}.${fieldName}`;
    const nestedError = getIn(errors, path) as unknown;
    const isFieldTouched = getIn(touched, path) as unknown;
    return typeof nestedError === 'string' &&
      (isFieldTouched === true || showValidationErrors || submitCount > 0)
      ? nestedError
      : undefined;
  };

  return (
    <FormGroup label={label} fieldId={fieldId} isRequired={isRequired}>
      <Stack hasGutter>
        {helperText && (
          <StackItem>
            <HelperText>
              <HelperTextItem id={`${fieldId}-helper-description`}>{helperText}</HelperTextItem>
            </HelperText>
          </StackItem>
        )}
        <StackItem>
          <FieldArray name={name}>
            {(helpers) => (
              <Stack hasGutter>
                {pairs.map((pair, index) => (
                  <StackItem key={index}>
                    <Split hasGutter>
                      <SplitItem isFilled>
                        <TextInput
                          id={`${fieldId}-${index}-key`}
                          aria-label={t('{{label}} key {{number}}', { label, number: index + 1 })}
                          placeholder={keyText}
                          value={pair.key}
                          onChange={(_event, value) =>
                            helpers.replace(index, { ...pair, key: value })
                          }
                          onBlur={() =>
                            void helpers.form.setFieldTouched(`${name}.${index}.key`, true)
                          }
                          validated={getPairFieldError(index, 'key') ? 'error' : 'default'}
                          aria-invalid={getPairFieldError(index, 'key') ? true : undefined}
                          aria-describedby={getFormFieldHelperDescribedBy(
                            `${fieldId}-${index}-key`,
                            getPairFieldError(index, 'key'),
                          )}
                        />
                        <FormFieldHelper
                          error={getPairFieldError(index, 'key')}
                          fieldId={`${fieldId}-${index}-key`}
                        />
                      </SplitItem>
                      <SplitItem isFilled>
                        <TextInput
                          id={`${fieldId}-${index}-value`}
                          aria-label={t('{{label}} value {{number}}', { label, number: index + 1 })}
                          placeholder={valueText}
                          value={pair.value}
                          onChange={(_event, value) => helpers.replace(index, { ...pair, value })}
                          onBlur={() =>
                            void helpers.form.setFieldTouched(`${name}.${index}.value`, true)
                          }
                          validated={getPairFieldError(index, 'value') ? 'error' : 'default'}
                          aria-invalid={getPairFieldError(index, 'value') ? true : undefined}
                          aria-describedby={getFormFieldHelperDescribedBy(
                            `${fieldId}-${index}-value`,
                            getPairFieldError(index, 'value'),
                          )}
                        />
                        <FormFieldHelper
                          error={getPairFieldError(index, 'value')}
                          fieldId={`${fieldId}-${index}-value`}
                        />
                      </SplitItem>
                      <SplitItem>
                        <Button
                          variant="plain"
                          aria-label={removeLabel}
                          onClick={() => helpers.remove(index)}
                          icon={<MinusCircleIcon />}
                          isDisabled={isRequired && field.value.length === 1}
                        />
                      </SplitItem>
                    </Split>
                  </StackItem>
                ))}
                <StackItem>
                  <Button
                    variant="link"
                    icon={<PlusCircleIcon />}
                    onClick={() => helpers.push({ key: '', value: '' })}
                  >
                    {addLabel}
                  </Button>
                </StackItem>
              </Stack>
            )}
          </FieldArray>
          <FormFieldHelper error={error} fieldId={fieldId} />
        </StackItem>
      </Stack>
    </FormGroup>
  );
};
