import { StorageTierState } from '@osac/types/private';

import { ResourceStatusLabel, type StatusKind } from '../Resource/ResourceStatusLabel';

interface StorageTierStatusLabelProps {
  state?: StorageTierState;
}

const STORAGE_TIER_STATUS_MAP: Record<StorageTierState, { status: StatusKind; text: string }> = {
  [StorageTierState.UNSPECIFIED]: { status: 'unspecified', text: 'Unspecified' },
  [StorageTierState.ACTIVE]: { status: 'ready', text: 'Active' },
};

const resolveStorageTierStatus = (
  state?: StorageTierState,
): { status: StatusKind; text: string } =>
  state !== undefined && state in STORAGE_TIER_STATUS_MAP
    ? STORAGE_TIER_STATUS_MAP[state]
    : STORAGE_TIER_STATUS_MAP[StorageTierState.UNSPECIFIED];

export const StorageTierStatusLabel = ({ state }: StorageTierStatusLabelProps) => {
  const { status, text } = resolveStorageTierStatus(state);

  return <ResourceStatusLabel status={status} text={text} />;
};
