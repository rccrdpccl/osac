import type { FieldMetaProps } from 'formik';

export const getVisibleFieldError = (
  meta: FieldMetaProps<unknown>,
  showValidationErrors: boolean,
): string | undefined => {
  const error = fieldErrorMessage(meta.error);
  if (!error) {
    return undefined;
  }
  if (meta.touched || showValidationErrors) {
    return error;
  }
  return undefined;
};

const fieldErrorMessage = (error: unknown): string | undefined => {
  if (!error) {
    return undefined;
  }
  if (typeof error === 'string') {
    return error;
  }
  if (typeof error === 'object' && 'id' in error) {
    const idError = (error as { id?: unknown }).id;
    return typeof idError === 'string' ? idError : undefined;
  }
  return undefined;
};
