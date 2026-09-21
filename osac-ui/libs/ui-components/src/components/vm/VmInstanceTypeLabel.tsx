import { Skeleton } from '@patternfly/react-core';

import type { InstanceType } from '@osac/types';

import { formatInstanceTypeDisplayName } from './utils';
import { useTranslation } from '../../hooks/useTranslation';

export interface VmInstanceTypeLabelProps {
  instanceType?: InstanceType;
  /** Fallback when `isLoading` is false but `instanceType` is unset (catalog lookup not found). */
  instanceTypeId?: string;
  isLoading?: boolean;
}

export const VmInstanceTypeLabel = ({
  instanceTypeId,
  instanceType,
  isLoading = false,
}: VmInstanceTypeLabelProps) => {
  const { t } = useTranslation();
  const trimmedId = instanceTypeId?.trim() ?? '';

  if (isLoading && trimmedId) {
    return <Skeleton width="150px" />;
  }

  return formatInstanceTypeDisplayName(instanceType, ` (${t('deprecated')})`, instanceTypeId);
};
