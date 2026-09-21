import { useEffect, useMemo, useRef } from 'react';
import { Alert, Button, Stack, StackItem } from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import type { ComputeInstanceCatalogItem } from '@osac/types';

import type { ComputeInstanceWizardValues } from './fields';
import {
  VIRTUAL_NETWORK_READY_LIST_FILTER,
  resourceDisplayName,
  securityGroupFilterForVirtualNetworkList,
  useSecurityGroups,
  useSubnets,
  useVirtualNetworks,
  virtualNetworkFilterForSubnetList,
} from '../../../../../api/v1/networking';
import { useTranslation } from '../../../../../hooks/useTranslation';
import { MultiSelectField } from '../../../../Form/MultiSelectField';
import OsacForm from '../../../../Form/OsacForm';
import { SelectField } from '../../../../Form/SelectField';

interface Props {
  catalogItem: ComputeInstanceCatalogItem | null;
}

export const VmNetworkingStep = ({ catalogItem }: Props) => {
  const { t } = useTranslation();
  const { values, setFieldValue } = useFormikContext<ComputeInstanceWizardValues>();
  const virtualNetworkId = values.spec.networking.virtualNetwork;

  const {
    data: virtualNetworks = [],
    isPending: virtualNetworksLoading,
    isError: virtualNetworksError,
    refetch: refetchVirtualNetworks,
  } = useVirtualNetworks({ filter: VIRTUAL_NETWORK_READY_LIST_FILTER });

  const subnetFilter = virtualNetworkId
    ? virtualNetworkFilterForSubnetList(virtualNetworkId)
    : undefined;
  const securityGroupFilter = virtualNetworkId
    ? securityGroupFilterForVirtualNetworkList(virtualNetworkId)
    : undefined;

  const {
    data: subnets = [],
    isPending: subnetsLoading,
    isError: subnetsError,
    refetch: refetchSubnets,
  } = useSubnets(subnetFilter ? { filter: subnetFilter } : {}, {
    enabled: Boolean(virtualNetworkId),
  });

  const {
    data: securityGroups = [],
    isPending: securityGroupsLoading,
    isError: securityGroupsError,
    refetch: refetchSecurityGroups,
  } = useSecurityGroups(securityGroupFilter ? { filter: securityGroupFilter } : {}, {
    enabled: Boolean(virtualNetworkId),
  });

  const virtualNetworkOptions = useMemo(
    () =>
      virtualNetworks.map((vn) => ({
        value: vn.id,
        label: resourceDisplayName(vn.metadata, vn.id),
      })),
    [virtualNetworks],
  );

  const subnetOptions = useMemo(
    () =>
      subnets.map((subnet) => ({
        value: subnet.id,
        label: resourceDisplayName(subnet.metadata, subnet.id),
      })),
    [subnets],
  );

  const securityGroupOptions = useMemo(
    () =>
      securityGroups.map((group) => ({
        value: group.id,
        label: resourceDisplayName(group.metadata, group.id),
      })),
    [securityGroups],
  );

  const previousVirtualNetworkIdRef = useRef(virtualNetworkId);

  useEffect(() => {
    const previous = previousVirtualNetworkIdRef.current;
    previousVirtualNetworkIdRef.current = virtualNetworkId;
    if (previous && previous !== virtualNetworkId) {
      void setFieldValue('spec.networking.subnet', '');
      void setFieldValue('spec.networking.securityGroups', []);
    }
  }, [setFieldValue, virtualNetworkId]);

  if (!catalogItem) {
    return null;
  }

  const listError = virtualNetworksError || subnetsError || securityGroupsError;
  const loadingPlaceholder = t('catalogProvision.common.loading');
  const subnetListLoading = Boolean(virtualNetworkId) && subnetsLoading;
  const securityGroupListLoading = Boolean(virtualNetworkId) && securityGroupsLoading;

  return (
    <Stack hasGutter>
      {listError ? (
        <StackItem>
          <Alert variant="danger" isInline title={t('catalogProvision.networking.loadError')}>
            <Button
              variant="link"
              isInline
              onClick={() => {
                void refetchVirtualNetworks();
                void refetchSubnets();
                void refetchSecurityGroups();
              }}
            >
              {t('catalogProvision.actions.retry')}
            </Button>
          </Alert>
        </StackItem>
      ) : null}
      <StackItem>
        <OsacForm>
          <SelectField
            name="spec.networking.virtualNetwork"
            label={t('catalogProvision.vm.fields.virtualNetwork')}
            fieldId="vm-virtual-network"
            isRequired
            autoSelectSingleOption
            isLoading={virtualNetworksLoading}
            loadingPlaceholder={loadingPlaceholder}
            placeholder={t('catalogProvision.vm.placeholders.selectVirtualNetwork')}
            options={virtualNetworkOptions}
          />
          <SelectField
            name="spec.networking.subnet"
            label={t('catalogProvision.vm.fields.subnet')}
            fieldId="vm-subnet"
            isRequired
            autoSelectSingleOption
            isLoading={subnetListLoading}
            isDisabled={!virtualNetworkId}
            loadingPlaceholder={loadingPlaceholder}
            placeholder={t('catalogProvision.vm.placeholders.selectSubnet')}
            options={subnetOptions}
          />
          <MultiSelectField
            name="spec.networking.securityGroups"
            label={t('catalogProvision.vm.fields.securityGroup')}
            fieldId="vm-security-group"
            isRequired
            autoSelectSingleOption
            isLoading={securityGroupListLoading}
            isDisabled={!virtualNetworkId}
            loadingPlaceholder={loadingPlaceholder}
            placeholder={t('catalogProvision.vm.placeholders.selectSecurityGroup')}
            options={securityGroupOptions}
          />
        </OsacForm>
      </StackItem>
    </Stack>
  );
};
