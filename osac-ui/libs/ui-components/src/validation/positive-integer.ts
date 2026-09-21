import type { TFunction } from 'i18next';
import * as Yup from 'yup';

const INT32_MAX = 2147483647;

export const positiveIntegerSchema = (t: TFunction, max: number = INT32_MAX): Yup.NumberSchema => {
  const schema = Yup.number()
    .transform((value: number, originalValue: unknown) =>
      originalValue === '' ? undefined : value,
    )
    .required(t('This field is required'))
    .typeError(t('Must be a whole number'))
    .integer(t('Must be a whole number'))
    .positive(t('Must be greater than zero'));

  return max === undefined ? schema : schema.max(max, t('Must be at most {{max}}', { max }));
};
