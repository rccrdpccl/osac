import { MessageInitShape } from '@bufbuild/protobuf';

import { IdentityProviderSchema } from '@osac/types';

import { IdentityProviderValues } from './values';

export const buildIdpUpdatePayload = (
  values: IdentityProviderValues,
): MessageInitShape<typeof IdentityProviderSchema> => {
  return {
    spec: {
      description: values.spec.description,
      title: values.spec.title,
      config: {
        case: 'oidc',
        value: {
          ...values.spec.config,
        },
      },
    },
  };
};

export const buildIdpCreatePayload = (
  values: IdentityProviderValues,
): MessageInitShape<typeof IdentityProviderSchema> => {
  return {
    metadata: {
      name: values.metadata.name,
    },
    spec: {
      description: values.spec.description,
      title: values.spec.title,
      config: {
        case: 'oidc',
        value: {
          ...values.spec.config,
        },
      },
      enabled: true,
    },
  };
};
