import type { TFunction } from 'i18next';

import { RoleBinding, RoleBindingState } from '@osac/types';

import {
  ResourceStatusLabel,
  StatusLabelProps,
} from '../../components/Resource/ResourceStatusLabel';
import { useTranslation } from '../../hooks/useTranslation';

interface RoleBindingStatusLabelProps {
  rb: RoleBinding;
}

const roleBindingStatusMap = (t: TFunction): Record<RoleBindingState, StatusLabelProps> => ({
  [RoleBindingState.READY]: {
    status: 'ready',
    text: t('Ready'),
  },
  [RoleBindingState.FAILED]: {
    status: 'failed',
    text: t('Failed'),
  },
  [RoleBindingState.PENDING]: {
    status: 'progressing',
    text: t('Pending'),
  },
  [RoleBindingState.UNSPECIFIED]: {
    status: 'unspecified',
    text: t('Unspecified'),
  },
});

const RoleBindingStatusLabel = ({ rb }: RoleBindingStatusLabelProps) => {
  const { t } = useTranslation();

  if (rb.metadata?.deletionTimestamp) {
    return <ResourceStatusLabel status="progressing" text={t('Deleting')} />;
  }

  const statusMap = roleBindingStatusMap(t);

  const status =
    rb.status?.state !== undefined
      ? statusMap[rb.status.state] || statusMap[RoleBindingState.UNSPECIFIED]
      : statusMap[RoleBindingState.UNSPECIFIED];

  return <ResourceStatusLabel {...status} />;
};

export default RoleBindingStatusLabel;
