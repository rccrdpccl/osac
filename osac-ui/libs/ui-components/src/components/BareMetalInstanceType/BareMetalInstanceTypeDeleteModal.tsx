import type { BareMetalInstanceType } from '@osac/types/private';
import { useDeleteBareMetalInstanceType } from '@osac/ui-components/api/v1/private/baremetal-instance-type';

import { useTranslation } from '../../hooks/useTranslation';
import DeleteResourceModal from '../Resource/DeleteResourceModal';

interface BareMetalInstanceTypeDeleteModalProps {
  instanceType: BareMetalInstanceType;
  onClose: VoidFunction;
  onSuccess: VoidFunction;
}

const BareMetalInstanceTypeDeleteModal = ({
  instanceType,
  onClose,
  onSuccess,
}: BareMetalInstanceTypeDeleteModalProps) => {
  const { t } = useTranslation();
  const deleteBareMetalInstanceType = useDeleteBareMetalInstanceType();

  return (
    <DeleteResourceModal
      resourceName={instanceType.metadata?.name || instanceType.id}
      label={t(
        'This permanently deletes the bare metal instance type. This action cannot be undone.',
      )}
      errorLabel={t('Failed to delete bare metal instance type')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deleteBareMetalInstanceType}
      variables={instanceType.id}
    />
  );
};

export default BareMetalInstanceTypeDeleteModal;
