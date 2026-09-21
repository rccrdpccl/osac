import type { TFunction } from 'i18next';

import { DiskImageLifecycle } from '@osac/types';

import { useTranslation } from '../../hooks/useTranslation';
import {
  ResourceLifecycleLabel,
  ResourceLifecycleLabelProps,
} from '../Resource/ResourceLifecycleLabel';

export interface DiskImageLifecycleLabelProps {
  lifecycle?: DiskImageLifecycle;
}

const diskImageLifecycleMap = (
  t: TFunction,
): Record<DiskImageLifecycle, ResourceLifecycleLabelProps> => ({
  [DiskImageLifecycle.AVAILABLE]: { lifecycle: 'active', text: t('Available') },
  [DiskImageLifecycle.DEPRECATED]: { lifecycle: 'deprecated', text: t('Deprecated') },
  [DiskImageLifecycle.OBSOLETE]: { lifecycle: 'obsolete', text: t('Obsolete') },
  [DiskImageLifecycle.UNSPECIFIED]: { lifecycle: 'unspecified', text: t('Unspecified') },
});

const DiskImageLifecycleLabel = ({ lifecycle }: DiskImageLifecycleLabelProps) => {
  const { t } = useTranslation();

  const lifecycleMap = diskImageLifecycleMap(t);

  const props =
    lifecycle !== undefined
      ? (lifecycleMap[lifecycle] ?? lifecycleMap[DiskImageLifecycle.UNSPECIFIED])
      : lifecycleMap[DiskImageLifecycle.UNSPECIFIED];

  return <ResourceLifecycleLabel {...props} />;
};

export default DiskImageLifecycleLabel;
