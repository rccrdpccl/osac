import type { FormikErrors } from 'formik';
import type { TFunction } from 'i18next';
import * as Yup from 'yup';

import { resourceNameSchema } from '@osac/ui-components/validation/resource-name';

import { SECRET_FILE_MAX_BYTES } from './values';
import type { SecretDataEntryValueType, SecretValues } from './values';

export const getSecretValidationSchema = (t: TFunction, _isEdit: boolean) =>
  Yup.object({
    metadata: Yup.object({
      name: resourceNameSchema(t),
    }),
    dataEntries: Yup.array()
      .min(1, t('At least one secret entry is required'))
      .of(
        Yup.object({
          key: Yup.string().required(t('Secret key is required')),
          valueType: Yup.mixed<SecretDataEntryValueType>()
            .oneOf(['text', 'file'])
            .required(t('Secret value type is required')),
          value: Yup.mixed<string | Uint8Array>()
            .test('text-required', t('Secret value is required'), (value, context) => {
              const entry = context.parent as { valueType?: SecretDataEntryValueType };
              return entry.valueType !== 'text' || (typeof value === 'string' && value.length > 0);
            })
            .test('file-required', t('Secret file is required'), (value, context) => {
              const entry = context.parent as { valueType?: SecretDataEntryValueType };
              return entry.valueType !== 'file' || value instanceof Uint8Array;
            })
            .test('file-max-size', t('Secret files must not exceed 1 MiB'), (value, context) => {
              const entry = context.parent as { valueType?: SecretDataEntryValueType };
              return (
                entry.valueType !== 'file' ||
                !(value instanceof Uint8Array) ||
                value.byteLength <= SECRET_FILE_MAX_BYTES
              );
            }),
        }),
      )
      .test('unique-secret-keys', t('Secret keys must be unique'), (entries, context) => {
        const dataEntries = (entries as SecretValues['dataEntries'] | undefined) ?? [];
        const seenKeys = new Set<string>();

        for (const [index, entry] of dataEntries.entries()) {
          if (!entry.key) {
            continue;
          }

          if (seenKeys.has(entry.key)) {
            return context.createError({
              path: `${context.path}[${index}].key`,
              message: t('Secret keys must be unique'),
            });
          }

          seenKeys.add(entry.key);
        }

        return true;
      }),
  });

export const secretStepHasErrors = (
  stepId: string,
  errors: FormikErrors<SecretValues>,
): boolean => {
  switch (stepId) {
    case 'general':
      return Boolean(errors.metadata?.name || errors.metadata?.project || errors.dataEntries);
    default:
      return false;
  }
};
