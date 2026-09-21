import { FormGroup, Split, SplitItem, TextArea, TextInput } from '@patternfly/react-core';
import { useField } from 'formik';

import { getVisibleFieldError } from './fieldError';
import { useShowFieldValidationErrors } from './FieldValidationContext';
import { FormFieldHelper, getFormFieldHelperDescribedBy } from './FormFieldHelper';

interface InputFieldProps {
  name: string;
  label: string;
  fieldId: string;
  isRequired?: boolean;
  isDisabled?: boolean;
  multiline?: boolean;
  rows?: number;
  resizeOrientation?: 'vertical' | 'horizontal' | 'both' | 'none';
  type?: 'text' | 'number' | 'password';
  helperText?: string;
  placeholder?: string;
  onBlur?: () => void;
  min?: number;
  max?: number;
  step?: number;
}

export const InputField = ({
  name,
  label,
  fieldId,
  isRequired = false,
  isDisabled = false,
  multiline = false,
  rows,
  resizeOrientation,
  type = 'text',
  helperText,
  placeholder,
  onBlur,
  min,
  max,
  step,
  children,
}: React.PropsWithChildren<InputFieldProps>) => {
  const [field, meta, helpers] = useField<string>(name);
  const showValidationErrors = useShowFieldValidationErrors();
  const error = getVisibleFieldError(meta, showValidationErrors);
  const validated = error ? 'error' : 'default';
  const helperDescribedBy = getFormFieldHelperDescribedBy(fieldId, error, helperText);
  const shouldTrimOnBlur = type === 'text' && !multiline;

  const handleBlur = (event: React.FocusEvent<HTMLInputElement | HTMLTextAreaElement>) => {
    field.onBlur(event);
    if (shouldTrimOnBlur) {
      const trimmed = (field.value ?? '').trim();
      if (trimmed !== field.value) {
        void helpers.setValue(trimmed);
      }
    }
    onBlur?.();
  };

  return (
    <FormGroup label={label} fieldId={fieldId} isRequired={isRequired}>
      {multiline ? (
        <TextArea
          id={fieldId}
          name={name}
          value={field.value ?? ''}
          placeholder={placeholder}
          rows={rows}
          resizeOrientation={resizeOrientation}
          onChange={(_event, value) => {
            void field.onChange({ target: { name, value } });
          }}
          onBlur={handleBlur}
          isDisabled={isDisabled}
          validated={validated}
          aria-invalid={error ? true : undefined}
          aria-describedby={helperDescribedBy}
        />
      ) : (
        <Split hasGutter>
          <SplitItem isFilled>
            <TextInput
              id={fieldId}
              name={name}
              type={type}
              value={field.value ?? ''}
              placeholder={placeholder}
              min={min}
              max={max}
              step={step}
              onChange={(_event, value) => {
                void field.onChange({ target: { name, value } });
              }}
              onBlur={handleBlur}
              isDisabled={isDisabled}
              validated={validated}
              aria-invalid={error ? true : undefined}
              aria-describedby={helperDescribedBy}
            />
          </SplitItem>
          {children && <SplitItem>{children}</SplitItem>}
        </Split>
      )}
      <FormFieldHelper error={error} description={helperText} fieldId={fieldId} />
    </FormGroup>
  );
};
