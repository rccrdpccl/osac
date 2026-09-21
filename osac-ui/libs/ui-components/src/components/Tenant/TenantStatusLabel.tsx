import type { TFunction } from 'i18next';

import { TenantState } from '@osac/types/private';

import {
  ResourceStatusLabel,
  StatusLabelProps,
} from '../../components/Resource/ResourceStatusLabel';
import { useTranslation } from '../../hooks/useTranslation';

interface TenantStatusLabelProps {
  state?: TenantState;
}

const tenantStatusMap = (t: TFunction): Record<TenantState, StatusLabelProps> => ({
  [TenantState.SYNCED]: {
    status: 'ready',
    text: t('Synced'),
  },
  [TenantState.FAILED]: {
    status: 'failed',
    text: t('Failed'),
  },
  [TenantState.PENDING]: {
    status: 'progressing',
    text: t('Pending'),
  },
  [TenantState.UNSPECIFIED]: {
    status: 'unspecified',
    text: t('Unspecified'),
  },
});

const TenantStatusLabel = ({ state }: TenantStatusLabelProps) => {
  const { t } = useTranslation();

  const statusMap = tenantStatusMap(t);

  const status = state ? statusMap[state] : statusMap[TenantState.UNSPECIFIED];

  return <ResourceStatusLabel {...status} />;
};

export default TenantStatusLabel;
