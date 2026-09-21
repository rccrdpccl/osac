import { type DiskImage, DiskImages } from '@osac/types';
import { useDeleteResource } from '@osac/ui-components/api/use-resource';
import DeleteResourceModal from '@osac/ui-components/components/Resource/DeleteResourceModal.tsx';

import { useTranslation } from '../../hooks/useTranslation';

interface DiskImageDeleteConfirmModalProps {
  diskImage: DiskImage;
  onClose: () => void;
  onSuccess: () => void;
}

const DiskImageDeleteConfirmModal = ({
  diskImage,
  onClose,
  onSuccess,
}: DiskImageDeleteConfirmModalProps) => {
  const { t } = useTranslation();
  const deleteDiskImage = useDeleteResource(DiskImages);
  const name = diskImage.metadata?.name ?? diskImage.id;

  return (
    <DeleteResourceModal
      resourceName={name}
      label={t('This permanently deletes the disk image. This action cannot be undone.')}
      errorLabel={t('Failed to delete disk image')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deleteDiskImage}
      variables={{ id: diskImage.id }}
    />
  );
};

export default DiskImageDeleteConfirmModal;
