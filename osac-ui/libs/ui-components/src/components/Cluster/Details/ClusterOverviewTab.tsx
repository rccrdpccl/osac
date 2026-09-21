import type { Cluster } from '@osac/types';

import { ClusterConfigurationCard } from './ClusterConfigurationCard';

interface ClusterOverviewTabProps {
  cluster: Cluster;
}

export const ClusterOverviewTab = ({ cluster }: ClusterOverviewTabProps) => {
  return <ClusterConfigurationCard cluster={cluster} />;
};
