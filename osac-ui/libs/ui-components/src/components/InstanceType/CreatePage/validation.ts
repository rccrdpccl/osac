import { TFunction } from 'i18next';
import * as Yup from 'yup';

import { positiveIntegerSchema } from '@osac/ui-components/validation/positive-integer';
import { resourceNameSchema } from '@osac/ui-components/validation/resource-name';

import type { InstanceTypeCreateFormValues } from './values';

const requiredForGpu = (t: TFunction) => t('Required when configuring a GPU');

export const getInstanceTypeCreateSchema = (t: TFunction) =>
  Yup.object({
    metadata: Yup.object({
      name: resourceNameSchema(t),
    }),
    spec: Yup.object({
      description: Yup.string(),
      cores: positiveIntegerSchema(t).required(t('Cores are required')),
      memoryGib: positiveIntegerSchema(t).required(t('Memory is required')),
      gpu: Yup.lazy((gpu: InstanceTypeCreateFormValues['spec']['gpu'] | undefined) => {
        const anyProvided = !!gpu?.pciDeviceSelector || !!gpu?.resourceName || !!gpu?.count;

        if (!anyProvided) {
          return Yup.mixed();
        }

        return Yup.object({
          pciDeviceSelector: Yup.string().required(requiredForGpu(t)),
          resourceName: Yup.string().required(requiredForGpu(t)),
          // No GPU-specific upper bound here; the backend enforces count <= 16.
          count: positiveIntegerSchema(t).required(requiredForGpu(t)),
        });
      }),
    }),
  });
