import { useNavigate, useParams } from 'react-router-dom';
import {
  ActionList,
  ActionListGroup,
  ActionListItem,
  Alert,
  Breadcrumb,
  BreadcrumbItem,
  Button,
  PageSection,
  Stack,
  StackItem,
  Title,
} from '@patternfly/react-core';
import { Formik } from 'formik';
import type { TFunction } from 'i18next';
import * as Yup from 'yup';

import type { StorageTier } from '@osac/types/private';
import { StorageProtocol } from '@osac/types/private';

import {
  STORAGE_BACKEND_READY_LIST_FILTER,
  usePrivateStorageBackend,
  usePrivateStorageBackends,
} from '../../api/v1/private/storage-backends';
import {
  useCreateStorageTier,
  usePrivateStorageTier,
  useUpdateStorageTier,
} from '../../api/v1/private/storage-tiers';
import { useTranslation } from '../../hooks/useTranslation';
import { getErrorMessage } from '../../utils/error';
import { positiveIntegerSchema } from '../../validation/positive-integer';
import { resourceNameSchema } from '../../validation/resource-name';
import NameField from '../catalogProvision/wizard/fields/NameField';
import { CheckboxField } from '../Form/CheckboxField';
import { InputField } from '../Form/InputField';
import LeaveFormConfirmation from '../Form/LeaveFormConfirmation';
import OsacForm from '../Form/OsacForm';
import { RadioButtonField } from '../Form/RadioButtonField';
import { SelectField, type SelectFieldOption } from '../Form/SelectField';
import ListPageBody from '../Page/ListPageBody';

const TIERS_LIST_PATH = '/admin/infrastructure/storage/tiers';

const PROTOCOL_BY_VALUE: Record<'NFS' | 'BLOCK', StorageProtocol> = {
  NFS: StorageProtocol.NFS,
  BLOCK: StorageProtocol.BLOCK,
};

const VALUE_BY_PROTOCOL: Partial<Record<StorageProtocol, 'NFS' | 'BLOCK'>> = {
  [StorageProtocol.NFS]: 'NFS',
  [StorageProtocol.BLOCK]: 'BLOCK',
};

type QosFieldKey =
  | 'protocol'
  | 'maxReadBandwidthMbs'
  | 'maxWriteBandwidthMbs'
  | 'encryptionEnabled';

const QOS_FIELD_KEYS: QosFieldKey[] = [
  'protocol',
  'maxReadBandwidthMbs',
  'maxWriteBandwidthMbs',
  'encryptionEnabled',
];

interface StorageTierFormValues {
  metadata: { name: string };
  description: string;
  backendId: string;
  protocol: '' | 'NFS' | 'BLOCK';
  maxReadBandwidthMbs: string;
  maxWriteBandwidthMbs: string;
  encryptionEnabled: boolean;
}

const getInitialValues = (tier?: StorageTier): StorageTierFormValues => {
  const backend = tier?.spec?.backends[0];
  return {
    metadata: { name: tier?.metadata?.name ?? '' },
    description: tier?.spec?.description ?? '',
    backendId: backend?.backendId ?? '',
    protocol: tier?.spec ? (VALUE_BY_PROTOCOL[tier.spec.protocol] ?? '') : '',
    maxReadBandwidthMbs: tier?.spec ? String(tier.spec.maxReadBandwidthMbs) : '',
    maxWriteBandwidthMbs: tier?.spec ? String(tier.spec.maxWriteBandwidthMbs) : '',
    encryptionEnabled: tier?.spec?.encryptionEnabled ?? false,
  };
};

const getStorageTierSchema = (t: TFunction) =>
  Yup.object({
    metadata: Yup.object({ name: resourceNameSchema(t) }),
    description: Yup.string(),
    backendId: Yup.string().required(t('Backend is required')),
    protocol: Yup.string()
      .oneOf(['NFS', 'BLOCK'], t('Protocol is required'))
      .required(t('Protocol is required')),
    maxReadBandwidthMbs: positiveIntegerSchema(t).required(t('Max read bandwidth is required')),
    maxWriteBandwidthMbs: positiveIntegerSchema(t).required(t('Max write bandwidth is required')),
    encryptionEnabled: Yup.boolean().required(),
  });

interface StorageTierFormProps {
  tier?: StorageTier;
  backendOptions: SelectFieldOption[];
  backendsLoading: boolean;
}

const StorageTierForm = ({ tier, backendOptions, backendsLoading }: StorageTierFormProps) => {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const isEdit = !!tier;

  const { mutateAsync: create, error: createError } = useCreateStorageTier();
  const { mutateAsync: update, error: updateError } = useUpdateStorageTier();
  const error = isEdit ? updateError : createError;

  const initialValues = getInitialValues(tier);

  const onSubmit = async (values: StorageTierFormValues) => {
    try {
      const protocol = PROTOCOL_BY_VALUE[values.protocol as 'NFS' | 'BLOCK'];
      const maxReadBandwidthMbs = Number(values.maxReadBandwidthMbs);
      const maxWriteBandwidthMbs = Number(values.maxWriteBandwidthMbs);
      const backendPayload = {
        backendId: values.backendId,
        maxReadBandwidthMbs,
        maxWriteBandwidthMbs,
        encryptionEnabled: values.encryptionEnabled,
      };

      if (tier) {
        const descriptionChanged = values.description !== initialValues.description;
        const spec: {
          protocol: StorageProtocol;
          maxReadBandwidthMbs: number;
          maxWriteBandwidthMbs: number;
          encryptionEnabled: boolean;
          backends: [Record<string, unknown>];
          description?: string;
        } = {
          protocol,
          maxReadBandwidthMbs,
          maxWriteBandwidthMbs,
          encryptionEnabled: values.encryptionEnabled,
          backends: [backendPayload],
        };
        if (descriptionChanged) {
          spec.description = values.description;
        }
        await update({ id: tier.id, metadata: { version: tier.metadata?.version ?? 0 }, spec });
        navigate(TIERS_LIST_PATH);
      } else {
        const created = await create({
          metadata: values.metadata,
          spec: {
            description: values.description,
            protocol,
            maxReadBandwidthMbs,
            maxWriteBandwidthMbs,
            encryptionEnabled: values.encryptionEnabled,
            backends: [backendPayload],
          },
        });
        navigate(`${TIERS_LIST_PATH}/${created.id}`);
      }
    } catch {
      // Surfaced via the mutation's own `error` state below; nothing further to do here.
    }
  };

  return (
    <>
      <PageSection hasBodyWrapper={false}>
        <Stack hasGutter>
          <Breadcrumb>
            <BreadcrumbItem>
              <Button variant="link" isInline onClick={() => navigate(TIERS_LIST_PATH)}>
                {t('Storage tiers')}
              </Button>
            </BreadcrumbItem>
            <BreadcrumbItem isActive>{isEdit ? t('Edit') : t('Create')}</BreadcrumbItem>
          </Breadcrumb>
          <Title headingLevel="h1" size="3xl">
            {isEdit ? t('Edit storage tier') : t('Create storage tier')}
          </Title>
        </Stack>
      </PageSection>
      <PageSection hasBodyWrapper={false}>
        <Formik
          initialValues={initialValues}
          validationSchema={getStorageTierSchema(t)}
          onSubmit={onSubmit}
        >
          {({ values, submitForm, isSubmitting }) => {
            const qosChanged =
              isEdit && QOS_FIELD_KEYS.some((key) => values[key] !== initialValues[key]);

            return (
              <Stack hasGutter>
                <LeaveFormConfirmation />
                <StackItem>
                  <OsacForm>
                    <NameField isDisabled={isEdit} />
                    <InputField
                      name="description"
                      label={t('Description')}
                      fieldId="tier-description"
                    />
                    <SelectField
                      name="backendId"
                      label={t('Backend')}
                      fieldId="tier-backend"
                      isRequired
                      isLoading={backendsLoading}
                      placeholder={t('Select a backend')}
                      options={backendOptions}
                    />
                    <RadioButtonField
                      name="protocol"
                      label={t('Protocol')}
                      fieldId="tier-protocol"
                      isRequired
                      isInline
                      options={[
                        { value: 'NFS', label: t('NFS') },
                        { value: 'BLOCK', label: t('Block') },
                      ]}
                    />
                    <InputField
                      name="maxReadBandwidthMbs"
                      label={t('Max read bandwidth (MB/s)')}
                      fieldId="tier-max-read-bandwidth"
                      type="number"
                      isRequired
                    />
                    <InputField
                      name="maxWriteBandwidthMbs"
                      label={t('Max write bandwidth (MB/s)')}
                      fieldId="tier-max-write-bandwidth"
                      type="number"
                      isRequired
                    />
                    <CheckboxField
                      name="encryptionEnabled"
                      label={t('Encryption enabled')}
                      fieldId="tier-encryption-enabled"
                    />
                  </OsacForm>
                </StackItem>

                {qosChanged && (
                  <StackItem>
                    <Alert variant="info" isInline title={t('QoS settings changed')}>
                      {t(
                        'Bandwidth changes take effect immediately for existing and new volumes. Changes to encryption or protocol require the associated StorageClass to be recreated before new volumes pick them up; existing volumes are unaffected.',
                      )}
                    </Alert>
                  </StackItem>
                )}

                {!!error && (
                  <StackItem>
                    <Alert
                      variant="danger"
                      title={
                        isEdit
                          ? t('Failed to update storage tier')
                          : t('Failed to create storage tier')
                      }
                      isInline
                    >
                      {getErrorMessage(error)}
                    </Alert>
                  </StackItem>
                )}
                <StackItem>
                  <ActionList>
                    <ActionListGroup>
                      <ActionListItem>
                        <Button
                          variant="primary"
                          onClick={submitForm}
                          isDisabled={isSubmitting}
                          isLoading={isSubmitting}
                        >
                          {isEdit ? t('Save') : t('Create')}
                        </Button>
                      </ActionListItem>
                      <ActionListItem>
                        <Button
                          variant="link"
                          onClick={() => navigate(TIERS_LIST_PATH)}
                          isDisabled={isSubmitting}
                        >
                          {t('Cancel')}
                        </Button>
                      </ActionListItem>
                    </ActionListGroup>
                  </ActionList>
                </StackItem>
              </Stack>
            );
          }}
        </Formik>
      </PageSection>
    </>
  );
};

const StorageTierCreatePage = () => {
  const { id } = useParams<{ id: string }>();
  const { data: tier, isLoading, error } = usePrivateStorageTier(id ?? '');

  const assignedBackendId = tier?.spec?.backends[0]?.backendId ?? '';
  const { data: readyBackends = [], isLoading: backendsLoading } = usePrivateStorageBackends({
    filter: STORAGE_BACKEND_READY_LIST_FILTER,
  });
  const { data: assignedBackend } = usePrivateStorageBackend(assignedBackendId);

  const backendOptions = readyBackends.map((backend) => ({
    value: backend.id,
    label: backend.metadata?.name ?? backend.id,
  }));
  if (assignedBackend && !backendOptions.some((option) => option.value === assignedBackend.id)) {
    backendOptions.push({
      value: assignedBackend.id,
      label: assignedBackend.metadata?.name ?? assignedBackend.id,
    });
  }

  if (id) {
    return (
      <ListPageBody isLoading={isLoading} error={error}>
        {tier && (
          <StorageTierForm
            tier={tier}
            backendOptions={backendOptions}
            backendsLoading={backendsLoading}
          />
        )}
      </ListPageBody>
    );
  }

  return <StorageTierForm backendOptions={backendOptions} backendsLoading={backendsLoading} />;
};

export default StorageTierCreatePage;
