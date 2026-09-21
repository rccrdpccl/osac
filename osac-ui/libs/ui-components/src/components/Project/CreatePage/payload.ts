import { ProjectCreateValues } from './values';

export const getCreateProjectPayload = (values: ProjectCreateValues) => ({
  metadata: {
    name: values.metadata.name,
    project: values.metadata.project === 'default' ? '' : values.metadata.project,
  },
  spec: {
    title: values.title,
    ...(values.description && { description: values.description }),
  },
});
