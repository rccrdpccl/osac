import { TFunction } from 'i18next';
import * as Yup from 'yup';

import { resourceNameSchema } from '@osac/ui-components/validation/resource-name';

export const getDiskImageCreateSchema = (t: TFunction) =>
  Yup.object({
    metadata: Yup.object({
      name: resourceNameSchema(t),
    }),
    spec: Yup.object({
      sourceRef: Yup.string().required(t('Source reference is required')),
      guestOsFamily: Yup.number().required(),
      architecture: Yup.array()
        .of(Yup.number().required())
        .min(1, t('Select at least one architecture'))
        .required(t('Select at least one architecture')),
    }),
  });
