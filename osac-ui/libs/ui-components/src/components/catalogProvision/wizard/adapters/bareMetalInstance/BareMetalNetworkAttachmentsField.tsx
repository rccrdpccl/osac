import { useEffect, useMemo, useRef } from 'react';
import {
  Alert,
  Button,
  FormFieldGroup,
  FormFieldGroupHeader,
  Stack,
  StackItem,
} from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import type { BareMetalInstanceWizardValues } from './fields';
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

export const BareMetalNetworkAttachmentsField = () => {
  const { t } = useTranslation();
  const { values, setFieldValue } = useFormikContext<BareMetalInstanceWizardValues>();
  const attachments = values.spec.networking.attachments;

  // Get virtual networks
  const {
    data: virtualNetworks = [],
    isPending: virtualNetworksLoading,
    isError: virtualNetworksError,
    refetch: refetchVirtualNetworks,
  } = useVirtualNetworks({ filter: VIRTUAL_NETWORK_READY_LIST_FILTER });

  // Get first attachment's virtual network for subnet/SG filtering
  const virtualNetworkId = attachments.length > 0 ? attachments[0].virtualNetwork : '';

  // Get subnets filtered by virtual network
  const subnetFilter = virtualNetworkId
    ? virtualNetworkFilterForSubnetList(virtualNetworkId)
    : undefined;
  const {
    data: subnets = [],
    isPending: subnetsLoading,
    isError: subnetsError,
    refetch: refetchSubnets,
  } = useSubnets(subnetFilter ? { filter: subnetFilter } : {}, {
    enabled: Boolean(virtualNetworkId),
  });

  // Get security groups filtered by virtual network
  const securityGroupFilter = virtualNetworkId
    ? securityGroupFilterForVirtualNetworkList(virtualNetworkId)
    : undefined;
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

  // Track previous virtualNetworkId to detect changes
  const previousVirtualNetworkIdRef = useRef(virtualNetworkId);

  useEffect(() => {
    const previous = previousVirtualNetworkIdRef.current;
    previousVirtualNetworkIdRef.current = virtualNetworkId;

    if (previous && previous !== virtualNetworkId) {
      void setFieldValue('spec.networking.attachments.0.subnet', '');
      void setFieldValue('spec.networking.attachments.0.securityGroups', []);
    }
  }, [virtualNetworkId, attachments, setFieldValue]);

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
        <Stack>
          {attachments.slice(0, 1).map((attachment) => (
            <StackItem key={attachment.id}>
              <FormFieldGroup
                header={
                  <FormFieldGroupHeader
                    titleText={{
                      text: t('Network attachment'),
                      id: 'bm-attachment-group-0',
                    }}
                  />
                }
              >
                <OsacForm>
                  <SelectField
                    name="spec.networking.attachments.0.virtualNetwork"
                    label={t('Virtual network')}
                    fieldId="bm-attachment-0-virtual-network"
                    isRequired
                    autoSelectSingleOption
                    isLoading={virtualNetworksLoading}
                    loadingPlaceholder={loadingPlaceholder}
                    placeholder={t('Select virtual network')}
                    options={virtualNetworkOptions}
                  />
                  <SelectField
                    name="spec.networking.attachments.0.subnet"
                    label={t('Subnet')}
                    fieldId="bm-attachment-0-subnet"
                    isRequired
                    autoSelectSingleOption
                    isLoading={subnetListLoading}
                    isDisabled={!virtualNetworkId}
                    loadingPlaceholder={loadingPlaceholder}
                    placeholder={t('Select subnet')}
                    options={subnetOptions}
                  />
                  <MultiSelectField
                    name="spec.networking.attachments.0.securityGroups"
                    label={t('Security groups')}
                    fieldId="bm-attachment-0-security-groups"
                    isRequired
                    autoSelectSingleOption
                    isLoading={securityGroupListLoading}
                    isDisabled={!virtualNetworkId}
                    loadingPlaceholder={loadingPlaceholder}
                    placeholder={t('Select security groups')}
                    options={securityGroupOptions}
                  />
                </OsacForm>
              </FormFieldGroup>
            </StackItem>
          ))}
        </Stack>
      </StackItem>
    </Stack>
  );
};
