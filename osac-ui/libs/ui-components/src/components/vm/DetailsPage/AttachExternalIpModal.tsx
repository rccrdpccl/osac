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
import { Formik } from 'formik';
import type { TFunction } from 'i18next';
import * as Yup from 'yup';

import type { ComputeInstance } from '@osac/types';

import { useAttachExternalIp, useExternalIPPools } from '../../../api/v1/external-ip';
import { useTranslation } from '../../../hooks/useTranslation';
import { getErrorMessage } from '../../../utils/error';
import OsacForm from '../../Form/OsacForm';
import { SelectField } from '../../Form/SelectField';

interface AttachExternalIpModalProps {
  vm: ComputeInstance;
  onClose: () => void;
  onSuccess: () => void;
}

interface FormValues {
  pool: string;
}

const validationSchema = (t: TFunction) =>
  Yup.object({
    pool: Yup.string().required(t('An external IP pool is required')),
  });

const AttachExternalIpModal = ({ vm, onClose, onSuccess }: AttachExternalIpModalProps) => {
  const { t } = useTranslation();
  const attachExternalIp = useAttachExternalIp();
  const { data: pools = [], isLoading, error: poolsError } = useExternalIPPools();

  const poolOptions = pools.map((pool) => ({
    value: pool.id,
    label: `${pool.metadata?.name ?? pool.id} (${pool.status?.available ?? 0} available)`,
  }));
  const noPoolsAvailable = !isLoading && !poolsError && poolOptions.length === 0;

  return (
    <Formik<FormValues>
      initialValues={{ pool: '' }}
      validationSchema={validationSchema(t)}
      onSubmit={async (values) => {
        try {
          await attachExternalIp.mutateAsync({
            computeInstanceId: vm.id,
            pool: values.pool,
          });
          onSuccess();
        } catch {
          // surfaced via attachExternalIp.error below
        }
      }}
    >
      {({ submitForm, isSubmitting, isValid }) => (
        <Modal
          variant="small"
          isOpen
          onClose={isSubmitting ? undefined : onClose}
          aria-labelledby="attach-external-ip-modal-title"
        >
          <ModalHeader title={t('Attach external IP')} labelId="attach-external-ip-modal-title" />
          <ModalBody>
            <Stack hasGutter>
              {noPoolsAvailable && (
                <StackItem>
                  <Alert variant="warning" title={t('No external IP pools available')} isInline>
                    {t('Contact your administrator to have an external IP pool provisioned.')}
                  </Alert>
                </StackItem>
              )}
              {!!poolsError && (
                <StackItem>
                  <Alert variant="danger" title={t('Error loading external IP pools')} isInline>
                    {getErrorMessage(poolsError)}
                  </Alert>
                </StackItem>
              )}
              <StackItem>
                <OsacForm>
                  <SelectField
                    name="pool"
                    label={t('External IP pool')}
                    fieldId="attach-external-ip-pool"
                    isRequired
                    isLoading={isLoading}
                    isDisabled={noPoolsAvailable}
                    placeholder={t('Select an external IP pool')}
                    options={poolOptions}
                    autoSelectSingleOption
                  />
                </OsacForm>
              </StackItem>
              {attachExternalIp.error && (
                <StackItem>
                  <Alert variant="danger" title={t('Failed to attach external IP')} isInline>
                    {getErrorMessage(attachExternalIp.error)}
                  </Alert>
                </StackItem>
              )}
            </Stack>
          </ModalBody>
          <ModalFooter>
            <Button variant="link" onClick={onClose} isDisabled={isSubmitting}>
              {t('Cancel')}
            </Button>
            <Button
              variant="primary"
              onClick={submitForm}
              isDisabled={isSubmitting || noPoolsAvailable || !isValid}
              isLoading={isSubmitting}
            >
              {t('Attach')}
            </Button>
          </ModalFooter>
        </Modal>
      )}
    </Formik>
  );
};

export default AttachExternalIpModal;
