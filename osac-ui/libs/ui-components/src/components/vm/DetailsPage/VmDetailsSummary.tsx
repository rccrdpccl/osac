import type { ComponentType, ReactNode, SVGProps } from 'react';
import {
  Card,
  CardBody,
  CardTitle,
  Flex,
  FlexItem,
  Grid,
  GridItem,
  Icon,
} from '@patternfly/react-core';
import GlobeIcon from '@patternfly/react-icons/dist/esm/icons/globe-icon';
import NetworkWiredIcon from '@patternfly/react-icons/dist/esm/icons/network-wired-icon';
import ServerIcon from '@patternfly/react-icons/dist/esm/icons/server-icon';

import type { ComputeInstance, InstanceType } from '@osac/types';

import { useTranslation } from '../../../hooks/useTranslation';
import { VmInstanceTypeLabel } from '../VmInstanceTypeLabel';

type SummaryIcon = ComponentType<SVGProps<SVGSVGElement>>;

interface SummaryCardProps {
  icon: SummaryIcon;
  title: string;
  children: ReactNode;
}

const SummaryCard = ({ icon: SummaryIconComponent, title, children }: SummaryCardProps) => (
  <Card isFullHeight>
    <CardTitle>
      <Flex alignItems={{ default: 'alignItemsCenter' }} spaceItems={{ default: 'spaceItemsSm' }}>
        <FlexItem>
          <Icon size="md">
            <SummaryIconComponent aria-hidden />
          </Icon>
        </FlexItem>
        <FlexItem>{title}</FlexItem>
      </Flex>
    </CardTitle>
    <CardBody>{children}</CardBody>
  </Card>
);

interface VmDetailsSummaryProps {
  vm: ComputeInstance;
  instanceType?: InstanceType;
  isInstanceTypeLoading?: boolean;
}

const VmDetailsSummary = ({
  vm,
  instanceType,
  isInstanceTypeLoading = false,
}: VmDetailsSummaryProps) => {
  const { t } = useTranslation();
  const instanceTypeId = vm.spec?.instanceType?.id;
  const externalIp = vm.status?.externalIpAddress;
  const internalIp = vm.status?.internalIpAddress;

  return (
    <Grid hasGutter role="group" aria-label={t('Virtual machine summary')}>
      <GridItem sm={6} md={4}>
        <SummaryCard icon={ServerIcon} title={t('Instance type')}>
          <VmInstanceTypeLabel
            instanceTypeId={instanceTypeId}
            instanceType={instanceType}
            isLoading={isInstanceTypeLoading}
          />
        </SummaryCard>
      </GridItem>
      <GridItem sm={6} md={4}>
        <SummaryCard icon={GlobeIcon} title={t('External IP')}>
          {externalIp || '—'}
        </SummaryCard>
      </GridItem>
      <GridItem sm={6} md={4}>
        <SummaryCard icon={NetworkWiredIcon} title={t('Internal IP')}>
          {internalIp || '—'}
        </SummaryCard>
      </GridItem>
    </Grid>
  );
};

export default VmDetailsSummary;
