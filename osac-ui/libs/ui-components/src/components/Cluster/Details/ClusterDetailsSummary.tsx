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
import CubeIcon from '@patternfly/react-icons/dist/esm/icons/cube-icon';
import NetworkWiredIcon from '@patternfly/react-icons/dist/esm/icons/network-wired-icon';
import ServerIcon from '@patternfly/react-icons/dist/esm/icons/server-icon';

import type { Cluster } from '@osac/types';

import { useTranslation } from '../../../hooks/useTranslation';
import { displayValue } from '../../../utils/detailFormatters';

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

interface ClusterDetailsSummaryProps {
  cluster: Cluster;
}

const sumNodeSetSizes = (nodeSets?: Record<string, { size?: number }>) =>
  Object.values(nodeSets ?? {}).reduce((sum, nodeSet) => sum + (nodeSet?.size ?? 0), 0);

const ClusterDetailsSummary = ({ cluster }: ClusterDetailsSummaryProps) => {
  const { t } = useTranslation();

  const workerCount = sumNodeSetSizes(cluster.spec?.nodeSets);
  const apiUrl = displayValue(cluster.status?.apiUrl);
  const consoleUrl = displayValue(cluster.status?.consoleUrl);

  return (
    <Grid hasGutter role="group" aria-label={t('Cluster summary')}>
      <GridItem sm={6} md={4}>
        <SummaryCard icon={ServerIcon} title={t('Worker nodes')}>
          {workerCount}
        </SummaryCard>
      </GridItem>
      <GridItem sm={6} md={4}>
        <SummaryCard icon={NetworkWiredIcon} title={t('API URL')}>
          {apiUrl}
        </SummaryCard>
      </GridItem>
      <GridItem sm={6} md={4}>
        <SummaryCard icon={CubeIcon} title={t('Console URL')}>
          {consoleUrl}
        </SummaryCard>
      </GridItem>
    </Grid>
  );
};

export default ClusterDetailsSummary;
