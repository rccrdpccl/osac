import {
  Alert,
  Button,
  Modal,
  ModalBody,
  ModalFooter,
  ModalHeader,
  Stack,
  StackItem,
} from '@patternfly/react-core';

import { IdentityProvider, IdentityProviders } from '@osac/types';
import { useUpdateResource } from '@osac/ui-components/api/use-resource';

import { getIdpName } from './utils';
import { useTranslation } from '../../hooks/useTranslation';
import { getErrorMessage } from '../../utils/error';

interface IdentityProviderEnableModalProps {
  idp: IdentityProvider;
  onClose: () => void;
  onSuccess: () => void;
}

const IdentityProviderEnableModal = ({
  idp,
  onClose,
  onSuccess,
}: IdentityProviderEnableModalProps) => {
  const { t } = useTranslation();
  const { mutate, isPending, error } = useUpdateResource(IdentityProviders);

  const isEnabled = !!idp.spec?.enabled;
  const idpName = getIdpName(idp);

  return (
    <Modal
      variant="small"
      isOpen
      onClose={isPending ? undefined : onClose}
      aria-labelledby="idp-enable-confirm-title"
    >
      <ModalHeader
        title={
          isEnabled ? t('Disable {{idpName}}?', { idpName }) : t('Enable {{idpName}}?', { idpName })
        }
        labelId="idp-enable-confirm-title"
      />
      <ModalBody>
        <Stack hasGutter>
          <StackItem>
            {isEnabled
              ? t('Are you sure you want to disable Identity provider {{idpName}}', { idpName })
              : t('Are you sure you want to enable Identity provider {{idpName}}', { idpName })}
          </StackItem>
          {error && (
            <StackItem>
              <Alert
                variant="danger"
                title={
                  isEnabled
                    ? t('Failed to disable Identity provider')
                    : t('Failed to enable Identity provider')
                }
                isInline
              >
                {getErrorMessage(error)}
              </Alert>
            </StackItem>
          )}
        </Stack>
      </ModalBody>
      <ModalFooter>
        <Button
          variant="primary"
          onClick={() =>
            mutate(
              {
                object: {
                  id: idp.id,
                  spec: { enabled: !isEnabled },
                },
              },
              { onSuccess },
            )
          }
          isDisabled={isPending}
          isLoading={isPending}
        >
          {isEnabled ? t('Disable') : t('Enable')}
        </Button>
        <Button variant="link" onClick={onClose} isDisabled={isPending}>
          {t('Cancel')}
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default IdentityProviderEnableModal;
