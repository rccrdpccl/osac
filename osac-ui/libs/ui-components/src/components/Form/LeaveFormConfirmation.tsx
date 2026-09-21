import { useBlocker } from 'react-router-dom';
import {
  Button,
  Content,
  Modal,
  ModalBody,
  ModalFooter,
  ModalHeader,
} from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import { useTranslation } from '../../hooks/useTranslation';

/**
 * Placed inside a <Formik> tree, blocks React Router navigation when the form is
 * dirty and not submitting, and shows a confirmation modal letting the user
 * either discard changes and proceed or stay on the page.
 */
const LeaveFormConfirmation = () => {
  const { t } = useTranslation();
  const { dirty, isSubmitting } = useFormikContext();

  const blocker = useBlocker(({ currentLocation, nextLocation }) => {
    return !isSubmitting && dirty && currentLocation.pathname !== nextLocation.pathname;
  });

  if (blocker.state !== 'blocked') {
    return null;
  }

  return (
    <Modal isOpen variant="small" aria-labelledby="leave-form-title">
      <ModalHeader
        title={t('Discard unsaved changes?')}
        titleIconVariant="warning"
        labelId="leave-form-title"
      />
      <ModalBody>
        <Content component="p">
          {t('Are you sure you want to leave? Your entered data will be lost.')}
        </Content>
      </ModalBody>
      <ModalFooter>
        <Button variant="danger" onClick={() => blocker.proceed?.()}>
          {t('Discard and close')}
        </Button>
        <Button variant="link" onClick={() => blocker.reset?.()}>
          {t('Keep editing')}
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default LeaveFormConfirmation;
