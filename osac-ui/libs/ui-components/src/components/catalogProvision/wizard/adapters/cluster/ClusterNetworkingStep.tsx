import { useMemo } from 'react';
import { Stack, StackItem } from '@patternfly/react-core';

import type { ClusterCatalogItem } from '@osac/types';

import { useTranslation } from '../../../../../hooks/useTranslation';
import { InputField } from '../../../../Form/InputField';
import OsacForm from '../../../../Form/OsacForm';
import { getCatalogFieldOverlay, readCatalogFieldDefinitions } from '../../catalogOverlay';

interface Props {
  catalogItem: ClusterCatalogItem | null;
}

export const ClusterNetworkingStep = ({ catalogItem }: Props) => {
  const { t } = useTranslation();

  const definitions = useMemo(() => readCatalogFieldDefinitions(catalogItem), [catalogItem]);
  const podCidrOverlay = useMemo(
    () => getCatalogFieldOverlay('network.pod_cidr', definitions, t('Pod CIDR')),
    [definitions, t],
  );
  const serviceCidrOverlay = useMemo(
    () => getCatalogFieldOverlay('network.service_cidr', definitions, t('Service CIDR')),
    [definitions, t],
  );

  if (!catalogItem) {
    return null;
  }

  return (
    <Stack hasGutter>
      <StackItem>
        <OsacForm>
          <InputField
            name="spec.network.podCidr"
            label={podCidrOverlay.label}
            fieldId="cluster-pod-cidr"
            isDisabled={!podCidrOverlay.editable}
            helperText={t('Use IPv4 CIDR notation (for example 10.128.0.0/14).')}
          />
          <InputField
            name="spec.network.serviceCidr"
            label={serviceCidrOverlay.label}
            fieldId="cluster-service-cidr"
            isDisabled={!serviceCidrOverlay.editable}
            helperText={t('Use IPv4 CIDR notation (for example 172.30.0.0/16).')}
          />
        </OsacForm>
      </StackItem>
    </Stack>
  );
};
