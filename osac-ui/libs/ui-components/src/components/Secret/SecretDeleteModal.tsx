import { Secret, Secrets } from '@osac/types';
import { useDeleteResource } from '@osac/ui-components/api/use-resource';

import { useTranslation } from '../../hooks/useTranslation';
import DeleteResourceModal from '../Resource/DeleteResourceModal';

interface SecretDeleteModalProps {
  secret: Secret;
  onClose: VoidFunction;
  onSuccess: VoidFunction;
}

const SecretDeleteModal = ({ secret, onClose, onSuccess }: SecretDeleteModalProps) => {
  const { t } = useTranslation();
  const deleteSecret = useDeleteResource(Secrets);

  return (
    <DeleteResourceModal
      resourceName={secret.metadata?.name || ''}
      label={t('This permanently deletes the secret. This action cannot be undone.')}
      errorLabel={t('Failed to delete secret')}
      onClose={onClose}
      onSuccess={onSuccess}
      mutation={deleteSecret}
      variables={{ id: secret.id }}
    />
  );
};

export default SecretDeleteModal;
