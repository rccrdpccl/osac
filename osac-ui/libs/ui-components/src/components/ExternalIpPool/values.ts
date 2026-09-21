import type { CidrIpFamily } from '@osac/ui-components/validation/cidr-validation';

import { type ResourceSelectValue, emptyResourceSelectValue } from '../Form/ResourceSelectField';

export const EXTERNAL_IP_POOLS_LIST_PATH = '/admin/infrastructure/external-ip-pools';

export const externalIpPoolDetailsPath = (id: string) => `${EXTERNAL_IP_POOLS_LIST_PATH}/${id}`;

export interface ExternalIpPoolFormValues {
  metadata: { name: string; tenant: ResourceSelectValue };
  ipFamily: '' | CidrIpFamily;
  cidrs: string[];
}

export const getExternalIpPoolValues = (): ExternalIpPoolFormValues => ({
  metadata: { name: '', tenant: emptyResourceSelectValue() },
  ipFamily: '',
  cidrs: [''],
});
