import { ProjectMembership, ProjectMembershipRole } from '@osac/types';

export interface ProjectMembershipCreateValues {
  metadata: {
    name: string;
  };
  users: string[];
  role: ProjectMembershipRole;
}

export const getInitialValues = (pm?: ProjectMembership): ProjectMembershipCreateValues => {
  if (pm) {
    return {
      metadata: {
        name: pm.metadata?.name || '',
      },
      role: pm.spec?.role || ProjectMembershipRole.VIEWER,
      users: pm.spec?.users.map((u) => u.name) || [],
    };
  }

  return {
    metadata: {
      name: '',
    },
    users: [],
    role: ProjectMembershipRole.VIEWER,
  };
};
