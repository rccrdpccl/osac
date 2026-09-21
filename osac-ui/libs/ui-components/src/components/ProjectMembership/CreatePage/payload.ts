import { ProjectMembershipCreateValues } from './values';

export const getUpdateProjectMembershipPayload = (values: ProjectMembershipCreateValues) => ({
  spec: {
    users: values.users.map((u) => ({ name: u })),
    role: values.role,
  },
});

export const getCreateProjectMembershipPayload = (
  values: ProjectMembershipCreateValues,
  projectName: string,
) => ({
  metadata: {
    name: values.metadata.name,
    project: projectName,
  },
  spec: {
    users: values.users.map((u) => ({ name: u })),
    role: values.role,
  },
});
