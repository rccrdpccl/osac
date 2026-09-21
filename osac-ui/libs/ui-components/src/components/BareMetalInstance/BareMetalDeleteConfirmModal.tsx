import type { BareMetalInstance } from '@osac/types';
import DeleteResourceModal from '@osac/ui-components/components/Resource/DeleteResourceModal.tsx';

import { useDeleteBareMetalInstance } from '../../api/v1/baremetal-instance';
import { useTranslation } from '../../hooks/useTranslation';

interface BareMetalDeleteConfirmModalProps {
  instance: BareMetalInstance;
  onClose: () => void;
  onSuccess: () => void;
}

const BareMetalDeleteConfirmModal = ({
  instance,
  onClose,
  onSuccess,
}: BareMetalDeleteConfirmModalProps) => {
  const { t } = useTranslation();
  const deleteInstance = useDeleteBareMetalInstance();
  const name = instance.metadata?.name ?? instance.id;

  return (
    <DeleteResourceModal
      resourceName={name}
      label={t('This permanently deletes the bare metal instance. This action cannot be undone.')}
      errorLabel={t('Failed to delete bare metal instance')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deleteInstance}
      variables={instance.id}
    />
  );
};

export default BareMetalDeleteConfirmModal;
