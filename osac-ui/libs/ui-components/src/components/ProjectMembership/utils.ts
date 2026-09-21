import { TFunction } from 'i18next';

import { ProjectMembershipRole } from '@osac/types';

export const getRoleLabel = (t: TFunction): Record<ProjectMembershipRole, string> => ({
  [ProjectMembershipRole.UNSPECIFIED]: t('Unspecified'),
  [ProjectMembershipRole.MANAGER]: t('Manager'),
  [ProjectMembershipRole.VIEWER]: t('Viewer'),
});
