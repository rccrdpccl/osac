import type { TFunction } from 'i18next';

import { Project, ProjectState } from '@osac/types';

import {
  ResourceStatusLabel,
  StatusLabelProps,
} from '../../components/Resource/ResourceStatusLabel';
import { useTranslation } from '../../hooks/useTranslation';

interface ProjectStatusLabelProps {
  project: Project;
}

const projectPhaseMap = (t: TFunction): Record<ProjectState, StatusLabelProps> => ({
  [ProjectState.ACTIVE]: {
    status: 'ready',
    text: t('Active'),
  },
  [ProjectState.FAILED]: {
    status: 'failed',
    text: t('Failed'),
  },
  [ProjectState.PENDING]: {
    status: 'progressing',
    text: t('Pending'),
  },
  [ProjectState.UNSPECIFIED]: {
    status: 'unspecified',
    text: t('Unspecified'),
  },

  [ProjectState.DELETING]: {
    status: 'progressing',
    text: t('Deleting'),
  },

  [ProjectState.DELETE_FAILED]: {
    status: 'failed',
    text: t('Delete failed'),
  },
});

const ProjectStatusLabel = ({ project }: ProjectStatusLabelProps) => {
  const { t } = useTranslation();

  const phaseMap = projectPhaseMap(t);

  const status =
    project.status?.state !== undefined
      ? phaseMap[project.status.state] || phaseMap[ProjectState.UNSPECIFIED]
      : phaseMap[ProjectState.UNSPECIFIED];

  return <ResourceStatusLabel {...status} />;
};

export default ProjectStatusLabel;
