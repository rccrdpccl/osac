import type { StorageTier } from '@osac/types/private';
import DeleteResourceModal from '@osac/ui-components/components/Resource/DeleteResourceModal.tsx';

import { useDeleteStorageTier } from '../../api/v1/private/storage-tiers';
import { useTranslation } from '../../hooks/useTranslation';

interface StorageTierDeleteConfirmModalProps {
  tier: StorageTier;
  onClose: () => void;
  onSuccess: () => void;
}

const StorageTierDeleteConfirmModal = ({
  tier,
  onClose,
  onSuccess,
}: StorageTierDeleteConfirmModalProps) => {
  const { t } = useTranslation();
  const deleteTier = useDeleteStorageTier();
  const tierName = tier.metadata?.name ?? tier.id;

  return (
    <DeleteResourceModal
      resourceName={tierName}
      label={t('This permanently deletes the storage tier. This action cannot be undone.')}
      errorLabel={t('Failed to delete storage tier')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deleteTier}
      variables={tier.id}
    />
  );
};

export default StorageTierDeleteConfirmModal;
