import { TFunction } from 'i18next';
import * as Yup from 'yup';

import { resourceNameSchema } from '@osac/ui-components/validation/resource-name';

export const validationSchema = (t: TFunction) =>
  Yup.object({
    metadata: Yup.object({
      name: resourceNameSchema(t),
      tenant: Yup.string().required(t('Tenant is required')),
    }),
    users: Yup.array().min(1, t('At least one user is required')),
    role: Yup.string().required(t('Role is required')),
  });
