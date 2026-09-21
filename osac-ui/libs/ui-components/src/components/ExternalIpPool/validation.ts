import type { FormikErrors } from 'formik';
import type { TFunction } from 'i18next';
import * as Yup from 'yup';

import { type CidrIpFamily, buildCidrSchema } from '@osac/ui-components/validation/cidr-validation';
import { resourceNameSchema } from '@osac/ui-components/validation/resource-name';

import type { ExternalIpPoolFormValues } from './values';

const cidrFieldSchema = (t: TFunction, ipFamily: CidrIpFamily) =>
  buildCidrSchema(t, ipFamily).required(t('CIDR is required'));

export const getExternalIpPoolSchema = (t: TFunction) =>
  Yup.object({
    metadata: Yup.object({
      name: resourceNameSchema(t),
      tenant: Yup.object({
        id: Yup.string().required(t('Tenant is required')),
        name: Yup.string(),
      }),
    }),
    ipFamily: Yup.string().required(t('IP family is required')),
    cidrs: Yup.array()
      .of(Yup.string().required(t('CIDR is required')))
      .when('ipFamily', {
        is: 'ipv4',
        then: (schema) => schema.of(cidrFieldSchema(t, 'ipv4')),
      })
      .when('ipFamily', {
        is: 'ipv6',
        then: (schema) => schema.of(cidrFieldSchema(t, 'ipv6')),
      })
      .min(1, t('At least one CIDR is required')),
  });

export const externalIpPoolStepHasErrors = (
  stepId: string,
  errors: FormikErrors<unknown>,
): boolean => {
  const poolErrors = errors as FormikErrors<ExternalIpPoolFormValues>;
  switch (stepId) {
    case 'pool':
      return Boolean(poolErrors.metadata?.name || poolErrors.ipFamily || poolErrors.cidrs);
    case 'tenant':
      return Boolean(poolErrors.metadata?.tenant);
    default:
      return false;
  }
};
