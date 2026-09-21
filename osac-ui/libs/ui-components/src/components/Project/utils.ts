import { TFunction } from 'i18next';

import { Project } from '@osac/types';
import { cel } from '@osac/ui-components/api/cel';

export const getProjectName = (project: Project, t: TFunction): string => {
  if (project.metadata?.name === '') {
    return t('Default');
  }
  return project.spec?.title || project.metadata?.name || project.id;
};

export const getFullProjectPath = (project: Project | undefined) => {
  return project?.metadata?.project
    ? `${project.metadata.project}.${project.metadata?.name}`
    : project?.metadata?.name || '';
};

export const fullProjectPathToQueryFilter = (fullProjectPath: string) => {
  if (!fullProjectPath.includes('.')) {
    return cel<Project>((filter) =>
      filter.and(
        filter.field('metadata.tenant').notEquals('shared'),
        filter.field('metadata.name').equals(fullProjectPath),
      ),
    );
  }

  const lastIndex = fullProjectPath.lastIndexOf('.');

  const parent = fullProjectPath.slice(0, lastIndex);
  const name = fullProjectPath.slice(lastIndex + 1);

  return cel<Project>((filter) =>
    filter.and(
      filter.field('metadata.tenant').notEquals('shared'),
      filter.field('metadata.name').equals(name),
      filter.field('metadata.project').equals(parent),
    ),
  );
};
