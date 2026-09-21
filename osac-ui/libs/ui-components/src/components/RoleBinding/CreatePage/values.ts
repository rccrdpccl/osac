import { RoleBinding } from '@osac/types';

export interface RoleBindingCreateFormValues {
  metadata: {
    name: string;
    tenant: string;
  };
  users: string[];
  role: string;
}

export const getInitialValues = (
  roleBinding: RoleBinding | undefined,
  tenant: string,
): RoleBindingCreateFormValues => {
  if (roleBinding) {
    return {
      metadata: {
        name: roleBinding.metadata?.name || '',
        tenant: roleBinding.metadata?.tenant || '',
      },
      users: roleBinding.spec?.users.map((u) => u.name) || [],
      role: roleBinding.spec?.role?.name || '',
    };
  }

  return {
    metadata: {
      name: '',
      tenant,
    },
    users: [],
    role: '',
  };
};
