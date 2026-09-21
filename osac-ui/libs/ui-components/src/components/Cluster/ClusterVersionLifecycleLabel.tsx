import { Tooltip } from '@patternfly/react-core';
import type { TFunction } from 'i18next';

import { type ClusterVersion, ClusterVersionState } from '@osac/types';

import { useTranslation } from '../../hooks/useTranslation';
import { Timestamp } from '../Primitives/Timestamp';
import {
  ResourceLifecycleLabel,
  ResourceLifecycleLabelProps,
} from '../Resource/ResourceLifecycleLabel';

export interface ClusterVersionLifecycleLabelProps {
  /** The resolved cluster version; the label derives state and deprecation timestamps from its spec. */
  clusterVersion?: ClusterVersion;
}

const clusterVersionLifecycleMap = (
  t: TFunction,
): Record<ClusterVersionState, ResourceLifecycleLabelProps> => ({
  [ClusterVersionState.ACTIVE]: { lifecycle: 'active', text: t('Active') },
  [ClusterVersionState.DEPRECATED]: { lifecycle: 'deprecated', text: t('Deprecated') },
  [ClusterVersionState.OBSOLETE]: { lifecycle: 'obsolete', text: t('Obsolete') },
  [ClusterVersionState.UNSPECIFIED]: { lifecycle: 'unspecified', text: t('Unspecified') },
});

const ClusterVersionLifecycleLabel = ({ clusterVersion }: ClusterVersionLifecycleLabelProps) => {
  const { t } = useTranslation();

  const state = clusterVersion?.spec?.state;
  const deprecation = clusterVersion?.spec?.deprecation;

  const lifecycleMap = clusterVersionLifecycleMap(t);
  const props =
    state !== undefined
      ? (lifecycleMap[state] ?? lifecycleMap[ClusterVersionState.UNSPECIFIED])
      : lifecycleMap[ClusterVersionState.UNSPECIFIED];

  // Only DEPRECATED/OBSOLETE carry a lifecycle timestamp worth surfacing.
  const timestamp =
    state === ClusterVersionState.DEPRECATED
      ? deprecation?.deprecationTimestamp
      : state === ClusterVersionState.OBSOLETE
        ? deprecation?.obsolescenceTimestamp
        : undefined;

  const tooltip = timestamp ? (
    <>
      {state === ClusterVersionState.OBSOLETE ? t('Obsolete since') : t('Deprecated since')}{' '}
      <Timestamp value={timestamp} />
    </>
  ) : undefined;

  const label = <ResourceLifecycleLabel {...props} />;
  // PatternFly Label renders a non-focusable span, so wrap it in a focusable
  // element to make the tooltip reachable by keyboard/screen reader, not just hover.
  return tooltip ? (
    <Tooltip content={tooltip}>
      <span tabIndex={0}>{label}</span>
    </Tooltip>
  ) : (
    label
  );
};

export default ClusterVersionLifecycleLabel;
