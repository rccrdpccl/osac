import { useNavigate } from 'react-router-dom';
import {
  Alert,
  Button,
  ClipboardCopy,
  FormGroup,
  Modal,
  ModalBody,
  ModalFooter,
  ModalHeader,
  Stack,
  StackItem,
} from '@patternfly/react-core';

import type { Tenant } from '@osac/types/private';

import { useTranslation } from '../../../hooks/useTranslation';

interface BreakGlassCredentialModalProps {
  tenant: Tenant;
}

const BreakGlassCredentialModal = ({ tenant }: BreakGlassCredentialModalProps) => {
  const { t } = useTranslation();
  const navigate = useNavigate();

  const username = tenant.status?.breakGlassCredentials?.username;
  const password = tenant.status?.breakGlassCredentials?.password;

  const onClose = () => navigate('/admin/tenants');

  return (
    <Modal variant="medium" isOpen onClose={onClose} aria-labelledby="break-glass-credential-title">
      <ModalHeader title={t('Break-glass credentials')} labelId="break-glass-credential-title" />
      {!!username && !!password ? (
        <>
          <ModalBody>
            <Stack hasGutter>
              <StackItem>
                <Alert
                  variant="warning"
                  title={t('Save these credentials now — they cannot be retrieved later.')}
                  isInline
                />
              </StackItem>
              <StackItem>
                <FormGroup label={t('Username')} fieldId="break-glass-username">
                  <ClipboardCopy isReadOnly hoverTip={t('Copy')} clickTip={t('Copied')}>
                    {username}
                  </ClipboardCopy>
                </FormGroup>
              </StackItem>
              <StackItem>
                <FormGroup label={t('Password')} fieldId="break-glass-password">
                  <ClipboardCopy isReadOnly hoverTip={t('Copy')} clickTip={t('Copied')}>
                    {password}
                  </ClipboardCopy>
                </FormGroup>
              </StackItem>
            </Stack>
          </ModalBody>
          <ModalFooter>
            <Button variant="primary" onClick={onClose}>
              {t('I have saved the credentials')}
            </Button>
          </ModalFooter>
        </>
      ) : (
        <>
          <ModalBody>
            <Alert
              variant="danger"
              title={t('Failed to retrieve break-glass credentials.')}
              isInline
            />
          </ModalBody>
          <ModalFooter>
            <Button variant="primary" onClick={onClose}>
              {t('Close')}
            </Button>
          </ModalFooter>
        </>
      )}
    </Modal>
  );
};

export default BreakGlassCredentialModal;
