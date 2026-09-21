import type { TFunction } from 'i18next';

import { InstanceTypeState } from '@osac/types/private';

import { useTranslation } from '../../hooks/useTranslation';
import {
  ResourceLifecycleLabel,
  ResourceLifecycleLabelProps,
} from '../Resource/ResourceLifecycleLabel';

export interface InstanceTypeLifecycleLabelProps {
  state?: InstanceTypeState;
}

const instanceTypeLifecycleMap = (
  t: TFunction,
): Record<InstanceTypeState, ResourceLifecycleLabelProps> => ({
  [InstanceTypeState.ACTIVE]: { lifecycle: 'active', text: t('Active') },
  [InstanceTypeState.DEPRECATED]: { lifecycle: 'deprecated', text: t('Deprecated') },
  [InstanceTypeState.OBSOLETE]: { lifecycle: 'obsolete', text: t('Obsolete') },
  [InstanceTypeState.UNSPECIFIED]: { lifecycle: 'unspecified', text: t('Unspecified') },
});

const InstanceTypeLifecycleLabel = ({ state }: InstanceTypeLifecycleLabelProps) => {
  const { t } = useTranslation();

  const lifecycleMap = instanceTypeLifecycleMap(t);

  const props =
    state !== undefined
      ? (lifecycleMap[state] ?? lifecycleMap[InstanceTypeState.UNSPECIFIED])
      : lifecycleMap[InstanceTypeState.UNSPECIFIED];

  return <ResourceLifecycleLabel {...props} />;
};

export default InstanceTypeLifecycleLabel;
