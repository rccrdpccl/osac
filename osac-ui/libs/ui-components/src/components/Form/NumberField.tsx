import { FormGroup, TextInput } from '@patternfly/react-core';
import { useField } from 'formik';

import { getVisibleFieldError } from './fieldError';
import { useShowFieldValidationErrors } from './FieldValidationContext';
import { FormFieldHelper, getFormFieldHelperDescribedBy } from './FormFieldHelper';

const INTEGER_INPUT_PATTERN = /^-?\d*$/;
const INVALID_INTEGER_INPUT_KEYS = new Set(['.', ',', 'e', 'E', '+']);

interface NumberFieldProps {
  name: string;
  label: string;
  fieldId: string;
  isRequired?: boolean;
  isDisabled?: boolean;
  helperText?: string;
  placeholder?: string;
  onBlur?: () => void;
  min?: number;
  max?: number;
  step?: number;
  type?: 'number' | 'bigint';
}

const NumberField = ({
  name,
  label,
  fieldId,
  isRequired = false,
  isDisabled = false,
  helperText,
  placeholder,
  onBlur,
  min,
  max,
  step,
  type = 'number',
}: React.PropsWithChildren<NumberFieldProps>) => {
  const [field, meta] = useField<number | bigint | undefined>(name);
  const showValidationErrors = useShowFieldValidationErrors();
  const error = getVisibleFieldError(meta, showValidationErrors);
  const validated = error ? 'error' : 'default';
  const helperDescribedBy = getFormFieldHelperDescribedBy(fieldId, error, helperText);

  return (
    <FormGroup label={label} fieldId={fieldId} isRequired={isRequired}>
      <TextInput
        id={fieldId}
        name={name}
        type={type === 'bigint' ? 'text' : 'number'}
        inputMode="numeric"
        value={field.value?.toString() ?? ''}
        placeholder={placeholder}
        min={min}
        max={max}
        step={step}
        onKeyDown={(event) => {
          if (INVALID_INTEGER_INPUT_KEYS.has(event.key)) {
            event.preventDefault();
          }
        }}
        onChange={(event, value) => {
          if (!INTEGER_INPUT_PATTERN.test(value)) {
            event.currentTarget.value = field.value?.toString() ?? '';
            return;
          }

          const numericValue =
            value === '' ? undefined : type === 'bigint' ? parseBigInt(value) : Number(value);
          void field.onChange({ target: { name, value: numericValue } });
        }}
        onBlur={(event) => {
          field.onBlur(event);
          onBlur?.();
        }}
        isDisabled={isDisabled}
        validated={validated}
        aria-invalid={error ? true : undefined}
        aria-describedby={helperDescribedBy}
      />
      <FormFieldHelper error={error} description={helperText} fieldId={fieldId} />
    </FormGroup>
  );
};

export default NumberField;

const parseBigInt = (value: string): bigint | undefined => {
  try {
    return BigInt(value);
  } catch {
    return undefined;
  }
};
