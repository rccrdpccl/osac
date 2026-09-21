import { TFunction } from 'i18next';
import * as Yup from 'yup';

import { resourceNameSchema } from '@osac/ui-components/validation/resource-name';

export const getProjectMembershipValidationSchema = (t: TFunction) =>
  Yup.object({
    metadata: Yup.object({
      name: resourceNameSchema(t),
    }),
    users: Yup.array().of(Yup.string()),
  });
