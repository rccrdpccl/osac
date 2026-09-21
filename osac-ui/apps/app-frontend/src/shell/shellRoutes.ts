import type { UserRole } from '@osac/ui-components/shellTypes';

export const defaultRouteForRole = (role: UserRole): string => {
  if (role === 'admin') {
    return '/admin/tenants';
  }
  if (role === 'tenant-idp-manager') {
    return '/tenant/identity-provider';
  }

  return '/catalog';
};
