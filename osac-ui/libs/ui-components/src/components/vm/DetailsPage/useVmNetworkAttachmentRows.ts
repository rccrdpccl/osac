import { useMemo } from 'react';

import type { ComputeInstance } from '@osac/types';

import {
  formatResourceIdForReview,
  formatResourceIdsForReview,
  useSecurityGroups,
  useSubnets,
  useVirtualNetworks,
} from '../../../api/v1/networking';

export type VmNetworkAttachmentRow = {
  virtualNetwork: string;
  subnet: string;
  securityGroups: string;
};

export const useVmNetworkAttachmentRows = (vm: ComputeInstance): VmNetworkAttachmentRow[] => {
  const { data: virtualNetworks = [] } = useVirtualNetworks();
  const { data: subnets = [] } = useSubnets();
  const { data: securityGroups = [] } = useSecurityGroups();

  return useMemo((): VmNetworkAttachmentRow[] => {
    const attachments = vm.spec?.networkAttachments ?? [];
    return attachments.map((attachment) => {
      const subnet = subnets.find((item) => item.id === attachment.subnet?.id);
      const virtualNetworkId = subnet?.spec?.virtualNetwork?.id ?? '';
      return {
        virtualNetwork: formatResourceIdForReview(virtualNetworkId, virtualNetworks),
        subnet: formatResourceIdForReview(attachment.subnet?.id ?? '', subnets),
        securityGroups: formatResourceIdsForReview(
          attachment.securityGroups?.map(({ id }) => id) ?? [],
          securityGroups,
        ),
      };
    });
  }, [vm.spec?.networkAttachments, subnets, virtualNetworks, securityGroups]);
};
