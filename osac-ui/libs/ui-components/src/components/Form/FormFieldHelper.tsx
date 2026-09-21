import { HelperText, HelperTextItem } from '@patternfly/react-core';

interface Props {
  error?: string;
  description?: string;
  fieldId: string;
}

export const getFormFieldHelperDescribedBy = (
  fieldId: string,
  error?: string,
  description?: string,
): string | undefined => {
  if (error) {
    return `${fieldId}-helper-error`;
  }
  if (description) {
    return `${fieldId}-helper-description`;
  }
  return undefined;
};

export const FormFieldHelper = ({ error, description, fieldId }: Props) => {
  if (error) {
    return (
      <HelperText>
        <HelperTextItem variant="error" id={`${fieldId}-helper-error`}>
          {error}
        </HelperTextItem>
      </HelperText>
    );
  }

  if (description) {
    return (
      <HelperText>
        <HelperTextItem id={`${fieldId}-helper-description`}>{description}</HelperTextItem>
      </HelperText>
    );
  }

  return null;
};
