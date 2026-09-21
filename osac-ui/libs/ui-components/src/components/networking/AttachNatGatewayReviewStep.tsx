import {
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
} from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import type {
  AttachNatGatewayExternalIpOption,
  AttachNatGatewayFormValues,
  AttachNatGatewayVirtualNetwork,
} from './AttachNatGatewayWizard.types';
import { useTranslation } from '../../hooks/useTranslation';

export interface AttachNatGatewayReviewStepProps {
  virtualNetwork: AttachNatGatewayVirtualNetwork;
  externalIpOptions: AttachNatGatewayExternalIpOption[];
}

const AttachNatGatewayReviewStep = ({
  virtualNetwork,
  externalIpOptions,
}: AttachNatGatewayReviewStepProps) => {
  const { t } = useTranslation();
  const { values } = useFormikContext<AttachNatGatewayFormValues>();

  return (
    <DescriptionList isCompact aria-label={t('Review')}>
      <DescriptionListGroup>
        <DescriptionListTerm>{t('Virtual network')}</DescriptionListTerm>
        <DescriptionListDescription>
          {virtualNetwork.metadata?.name ?? virtualNetwork.id}
        </DescriptionListDescription>
      </DescriptionListGroup>
      <DescriptionListGroup>
        <DescriptionListTerm>{t('IPv4 CIDR')}</DescriptionListTerm>
        <DescriptionListDescription>
          <code>{virtualNetwork.spec?.ipv4Cidr ?? '—'}</code>
        </DescriptionListDescription>
      </DescriptionListGroup>
      <DescriptionListGroup>
        <DescriptionListTerm>{t('Name')}</DescriptionListTerm>
        <DescriptionListDescription>{values.metadata.name || '—'}</DescriptionListDescription>
      </DescriptionListGroup>
      <DescriptionListGroup>
        <DescriptionListTerm>{t('External IP')}</DescriptionListTerm>
        <DescriptionListDescription>
          {externalIpOptions.find((option) => option.value === values.externalIpId)?.label ?? '—'}
        </DescriptionListDescription>
      </DescriptionListGroup>
    </DescriptionList>
  );
};

export default AttachNatGatewayReviewStep;
