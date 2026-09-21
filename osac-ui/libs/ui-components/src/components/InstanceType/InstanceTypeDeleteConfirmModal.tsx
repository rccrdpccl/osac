import type { InstanceType as PrivateInstanceType } from '@osac/types/private';
import DeleteResourceModal from '@osac/ui-components/components/Resource/DeleteResourceModal.tsx';

import { useDeleteInstanceType } from '../../api/v1/private/instance-type';
import { useTranslation } from '../../hooks/useTranslation';

interface InstanceTypeDeleteConfirmModalProps {
  instanceType: PrivateInstanceType;
  onClose: () => void;
  onSuccess: () => void;
}

const InstanceTypeDeleteConfirmModal = ({
  instanceType,
  onClose,
  onSuccess,
}: InstanceTypeDeleteConfirmModalProps) => {
  const { t } = useTranslation();
  const deleteInstanceType = useDeleteInstanceType();
  const name = instanceType.metadata?.name ?? instanceType.id;

  return (
    <DeleteResourceModal
      resourceName={name}
      label={t('This permanently deletes the instance type. This action cannot be undone.')}
      errorLabel={t('Failed to delete instance type')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deleteInstanceType}
      variables={instanceType.id}
    />
  );
};

export default InstanceTypeDeleteConfirmModal;
