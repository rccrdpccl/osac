import { TFunction } from 'i18next';
import * as Yup from 'yup';

import { resourceNameSchema } from '@osac/ui-components/validation/resource-name';

const DOMAIN_LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

const isValidDomain = (value: string): boolean => {
  if (value.length > 253) {
    return false;
  }
  const labels = value.split('.');
  if (labels.length < 2) {
    return false;
  }
  return labels.every((label) => DOMAIN_LABEL.test(label));
};

export const getTenantSchema = (t: TFunction) =>
  Yup.object({
    name: resourceNameSchema(t),
    domains: Yup.array()
      .of(
        Yup.string()
          .required(t('Domain is required'))
          .test(
            'valid-domain',
            t('Must be a valid domain (e.g. example.com)'),
            (value) => !!value && isValidDomain(value),
          ),
      )
      .test('unique-domains', t('Domains must be unique'), (domains) => {
        if (!domains) {
          return true;
        }
        const nonEmpty = domains.filter(Boolean);
        return new Set(nonEmpty).size === nonEmpty.length;
      }),
  });
