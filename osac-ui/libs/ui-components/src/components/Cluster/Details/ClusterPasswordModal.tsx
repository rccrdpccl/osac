import {
  Alert,
  AlertActionLink,
  Button,
  ClipboardCopy,
  Modal,
  ModalBody,
  ModalFooter,
  ModalHeader,
  Spinner,
  Stack,
  StackItem,
} from '@patternfly/react-core';

import { useFetchClusterPassword } from '../../../api/v1/cluster';
import { useTranslation } from '../../../hooks/useTranslation';
import { getErrorMessage } from '../../../utils/error';

interface ClusterPasswordModalProps {
  passwordSecretId: string;
  onClose: () => void;
}

const ClusterPasswordModal = ({ passwordSecretId, onClose }: ClusterPasswordModalProps) => {
  const { t } = useTranslation();
  const { password, isPending, error, retry } = useFetchClusterPassword(passwordSecretId);

  return (
    <Modal variant="small" isOpen onClose={onClose} aria-labelledby="cluster-password-title">
      <ModalHeader title={t('Cluster password')} labelId="cluster-password-title" />
      <ModalBody>
        <Stack hasGutter>
          {isPending && (
            <StackItem>
              <Spinner size="lg" aria-label={t('Loading cluster password')} />
            </StackItem>
          )}
          {!!error && (
            <StackItem>
              <Alert
                variant="danger"
                title={t('Failed to load cluster password')}
                isInline
                actionLinks={<AlertActionLink onClick={retry}>{t('Retry')}</AlertActionLink>}
              >
                {getErrorMessage(error)}
              </Alert>
            </StackItem>
          )}
          {password && (
            <StackItem>
              <ClipboardCopy isReadOnly hoverTip={t('Copy')} clickTip={t('Copied')}>
                {password}
              </ClipboardCopy>
            </StackItem>
          )}
        </Stack>
      </ModalBody>
      <ModalFooter>
        <Button variant="link" onClick={onClose}>
          {t('Close')}
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default ClusterPasswordModal;
