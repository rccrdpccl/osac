import { ExternalIPPools } from '@osac/types/private';
import type { ExternalIPPool } from '@osac/types/private';
import DeleteResourceModal from '@osac/ui-components/components/Resource/DeleteResourceModal.tsx';

import { useDeleteResource } from '../../api/use-resource';
import { useTranslation } from '../../hooks/useTranslation';

interface ExternalIpPoolDeleteConfirmModalProps {
  pool: ExternalIPPool;
  onClose: () => void;
  onSuccess: () => void;
}

const ExternalIpPoolDeleteConfirmModal = ({
  pool,
  onClose,
  onSuccess,
}: ExternalIpPoolDeleteConfirmModalProps) => {
  const { t } = useTranslation();
  const deletePool = useDeleteResource(ExternalIPPools);
  const poolName = pool.metadata?.name ?? pool.id;

  return (
    <DeleteResourceModal
      resourceName={poolName}
      label={t(
        'This permanently deletes the external IP pool. Pools with allocated IPs cannot be deleted. This action cannot be undone.',
      )}
      errorLabel={t('Failed to delete external IP pool')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deletePool}
      variables={{ id: pool.id }}
    />
  );
};

export default ExternalIpPoolDeleteConfirmModal;
