import { FormikErrors } from 'formik';
import type { TFunction } from 'i18next';
import * as Yup from 'yup';

import { IdentityProviderValues } from './values';

const urlSchema = (t: TFunction) =>
  Yup.string().url(t('Must be a valid URL (e.g. https://example.com)'));

export const getIdentityProviderSchema = (t: TFunction, isEdit: boolean) =>
  Yup.object({
    metadata: Yup.object({
      name: isEdit ? Yup.mixed() : Yup.string(),
    }),
    spec: Yup.object({
      title: Yup.string(),
      description: Yup.string(),
      config: Yup.object({
        clientId: Yup.string().required(t('Client ID is required')),
        clientSecretSecret: Yup.object({
          name: Yup.string().required(t('Client secret is required')),
        }),
        issuer: urlSchema(t).required(t('Issuer is required')),
        authorizationUrl: urlSchema(t).required(t('Authorization URL is required')),
        tokenUrl: Yup.string()
          .required(t('Token URL is required'))
          .url(t('Must be a valid URL (e.g. https://example.com)')),
        defaultScopes: Yup.string(),
        userInfoUrl: urlSchema(t),
        jwksUrl: urlSchema(t),
        logoutUrl: urlSchema(t),
      }),
    }),
  });

export const idpStepHasErrors = (
  stepId: string,
  errors: FormikErrors<IdentityProviderValues>,
): boolean => {
  switch (stepId) {
    case 'general':
      return Boolean(errors.metadata?.name || errors.spec?.description || errors.spec?.title);
    case 'configuration':
      return Boolean(
        errors.spec?.config?.authorizationUrl ||
        errors.spec?.config?.clientId ||
        errors.spec?.config?.clientSecretSecret?.name ||
        errors.spec?.config?.defaultScopes ||
        errors.spec?.config?.issuer ||
        errors.spec?.config?.issuer ||
        errors.spec?.config?.jwksUrl ||
        errors.spec?.config?.logoutUrl ||
        errors.spec?.config?.tokenUrl ||
        errors.spec?.config?.userInfoUrl ||
        errors.spec?.config?.validateSignature,
      );
    default:
      return false;
  }
};
