import type { TFunction } from 'i18next';
import * as Yup from 'yup';

const DNS_LABEL_PATTERN = /^[a-z0-9-]+$/;

/** Yup schema for metadata.name — aligned with fulfillment-service validateName (RFC 1035 DNS labels). */
export const resourceNameSchema = (t: TFunction): Yup.StringSchema =>
  Yup.string()
    .required(t('Name is required'))
    .max(63, t('Name must be at most 63 characters long'))
    .test(
      'dns-label-charset',
      t('Name must only contain lowercase letters (a-z), digits (0-9), and hyphens (-)'),
      (value) => {
        if (!value) {
          return true;
        }
        return DNS_LABEL_PATTERN.test(value);
      },
    )
    .test(
      'dns-label-leading-hyphen',
      t('Name cannot start with a hyphen'),
      (value) => !value || !value.startsWith('-'),
    )
    .test(
      'dns-label-trailing-hyphen',
      t('Name cannot end with a hyphen'),
      (value) => !value || !value.endsWith('-'),
    );
