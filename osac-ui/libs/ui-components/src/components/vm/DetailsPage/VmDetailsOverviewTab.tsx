import { Card, CardBody, CardTitle, Grid, GridItem } from '@patternfly/react-core';

import type { ComputeInstance } from '@osac/types';

import VmDetailsCard from './VmDetailsCard';
import VmStorageCard from './VmStorageCard';
import VmUserDataCard from './VmUserDataCard';
import { useTranslation } from '../../../hooks/useTranslation';
import { ResourceConditionsTable } from '../../Resource/ResourceConditionsTable';

interface Props {
  vm: ComputeInstance;
}

const VmDetailsOverviewTab = ({ vm }: Props) => {
  const { t } = useTranslation();
  const conditions = vm.status?.conditions ?? [];

  return (
    <Grid hasGutter>
      <GridItem md={6}>
        <VmDetailsCard vm={vm} />
      </GridItem>
      <GridItem md={6}>
        <Card isFullHeight>
          <CardTitle>{t('Conditions')}</CardTitle>
          <CardBody>
            <ResourceConditionsTable
              ariaLabel={t('Virtual machine conditions')}
              conditions={conditions}
              conditionResourceKind="compute_instance"
            />
          </CardBody>
        </Card>
      </GridItem>
      <GridItem span={12}>
        <VmStorageCard vm={vm} />
      </GridItem>
      <GridItem span={12}>
        <VmUserDataCard vm={vm} />
      </GridItem>
    </Grid>
  );
};

export default VmDetailsOverviewTab;
