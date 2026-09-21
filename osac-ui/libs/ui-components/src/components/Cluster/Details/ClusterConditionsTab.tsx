import { Card, CardBody, CardTitle } from '@patternfly/react-core';

import type { Cluster } from '@osac/types';

import { ResourceConditionsTable } from '../../Resource/ResourceConditionsTable';

interface ClusterConditionsTabProps {
  cluster: Cluster;
}

export const ClusterConditionsTab = ({ cluster }: ClusterConditionsTabProps) => {
  const conditions = cluster.status?.conditions ?? [];

  return (
    <Card>
      <CardTitle>Conditions</CardTitle>
      <CardBody>
        <ResourceConditionsTable
          ariaLabel="Cluster conditions"
          conditions={conditions}
          conditionResourceKind="cluster"
        />
      </CardBody>
    </Card>
  );
};
