import { TFunction } from 'i18next';

/** OIDC shell roles mapped from Keycloak realm roles and groups. */
export type UserRole = 'admin' | 'tenant-idp-manager' | 'tenant-admin' | 'tenant-user';

export const userRoleLabels = (t: TFunction): Record<UserRole, string> => ({
  admin: t('Cloud provider admin'),
  'tenant-idp-manager': t('IdP manager'),
  'tenant-admin': t('Tenant admin'),
  'tenant-user': t('Tenant user'),
});
