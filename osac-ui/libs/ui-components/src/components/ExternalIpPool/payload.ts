import { IPFamily } from '@osac/types/private';
import type { CidrIpFamily } from '@osac/ui-components/validation/cidr-validation';

import type { ExternalIpPoolFormValues } from './values';

const IP_FAMILY_BY_VALUE: Record<CidrIpFamily, IPFamily> = {
  ipv4: IPFamily.IP_FAMILY_IPV4,
  ipv6: IPFamily.IP_FAMILY_IPV6,
};

export const toCreateRequest = (values: ExternalIpPoolFormValues) => ({
  object: {
    metadata: {
      name: values.metadata.name,
      tenant: values.metadata.tenant.id,
    },
    spec: {
      ipFamily: values.ipFamily
        ? IP_FAMILY_BY_VALUE[values.ipFamily]
        : IPFamily.IP_FAMILY_UNSPECIFIED,
      cidrs: values.cidrs,
    },
  },
});
