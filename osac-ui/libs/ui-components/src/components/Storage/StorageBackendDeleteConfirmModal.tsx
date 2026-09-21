import type { StorageBackend } from '@osac/types/private';
import DeleteResourceModal from '@osac/ui-components/components/Resource/DeleteResourceModal.tsx';

import { useDeleteStorageBackend } from '../../api/v1/private/storage-backends';
import { useTranslation } from '../../hooks/useTranslation';

interface StorageBackendDeleteConfirmModalProps {
  backend: StorageBackend;
  onClose: () => void;
  onSuccess: () => void;
}

const StorageBackendDeleteConfirmModal = ({
  backend,
  onClose,
  onSuccess,
}: StorageBackendDeleteConfirmModalProps) => {
  const { t } = useTranslation();
  const deleteBackend = useDeleteStorageBackend();
  const backendName = backend.metadata?.name ?? backend.id;

  return (
    <DeleteResourceModal
      resourceName={backendName}
      label={t('This permanently deletes the storage backend. This action cannot be undone.')}
      errorLabel={t('Failed to delete storage backend')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deleteBackend}
      variables={backend.id}
    />
  );
};

export default StorageBackendDeleteConfirmModal;
