import { useParams } from 'react-router-dom';

import VmDetails from './DetailsPage/VmDetails';
import { getVmDetailTabLabels } from './vm-detail-tabs';
import { useComputeInstance } from '../../api/v1/compute-instance';
import { useTranslation } from '../../hooks/useTranslation';
import { ResourceDetailsPageError } from '../Resource/ResourceDetailsPageError';
import { ResourceDetailsPageLoading } from '../Resource/ResourceDetailsPageLoading';

export const VmDetailsPage = () => {
  const { t } = useTranslation();
  const { id } = useParams() as { id: string };
  const { data: vm, isLoading, isError, error, refetch } = useComputeInstance(id);

  if (isLoading) {
    return (
      <ResourceDetailsPageLoading
        parentTo="/vms"
        parentLabel={t('Virtual machines')}
        tabLabels={getVmDetailTabLabels(t)}
        tabsId="vm-detail-tabs-loading"
        cardCount={2}
      />
    );
  }

  if (isError) {
    return (
      <ResourceDetailsPageError
        parentTo="/vms"
        parentLabel={t('Virtual machines')}
        resourceLabel="virtual machine"
        error={error}
        onRetry={() => void refetch()}
      />
    );
  }

  if (!vm) {
    return (
      <ResourceDetailsPageError
        parentTo="/vms"
        parentLabel={t('Virtual machines')}
        resourceLabel="virtual machine"
        variant="not-found"
      />
    );
  }

  return <VmDetails vm={vm} />;
};
