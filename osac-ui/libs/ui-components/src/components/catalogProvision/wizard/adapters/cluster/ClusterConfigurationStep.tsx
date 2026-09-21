import { useMemo } from 'react';
import { Alert, Button, FormSection, Stack, StackItem } from '@patternfly/react-core';
import { useField } from 'formik';

import { type ClusterCatalogItem } from '@osac/types';

import ClusterNodeSetsArrayField from './ClusterNodeSetsArrayField';
import { CLUSTER_VERSION_WIRE_PATH } from './fields';
import { findVersionByName, isDeprecatedVersion, versionDisplayName } from './versionUtils';
import {
  CLUSTER_VERSION_ACTIVE_LIST_FILTER,
  useClusterVersions,
} from '../../../../../api/v1/cluster-versions';
import { useTranslation } from '../../../../../hooks/useTranslation';
import { getErrorMessage } from '../../../../../utils/error';
import OsacForm from '../../../../Form/OsacForm';
import { SelectField } from '../../../../Form/SelectField';
import { getCatalogFieldOverlay, readCatalogFieldDefinitions } from '../../catalogOverlay';

interface Props {
  catalogItem: ClusterCatalogItem | null;
}

const ClusterConfigurationStep = ({ catalogItem }: Props) => {
  const { t } = useTranslation();

  const {
    data: versions = [],
    isLoading: versionsLoading,
    error: versionsError,
    refetch: refetchVersions,
  } = useClusterVersions({ filter: CLUSTER_VERSION_ACTIVE_LIST_FILTER });

  const [versionField] = useField<string>('spec.versionName');
  const isSelectedDeprecated = isDeprecatedVersion(findVersionByName(versions, versionField.value));

  const versionOptions = useMemo(
    () =>
      versions.map((version) => {
        const name = version.metadata?.name ?? '';
        const label = versionDisplayName(version, name);
        return {
          value: name,
          label: isDeprecatedVersion(version)
            ? t('{{version}} (deprecated)', { version: label })
            : label,
        };
      }),
    [versions, t],
  );

  const definitions = useMemo(() => readCatalogFieldDefinitions(catalogItem), [catalogItem]);
  const versionOverlay = useMemo(
    () => getCatalogFieldOverlay(CLUSTER_VERSION_WIRE_PATH, definitions, t('Version')),
    [definitions, t],
  );

  if (!catalogItem) {
    return null;
  }

  return (
    <Stack hasGutter>
      {versionsError ? (
        <StackItem>
          <Alert variant="danger" isInline title={t('Could not load cluster versions')}>
            <Stack hasGutter>
              <StackItem>{getErrorMessage(versionsError)}</StackItem>
              <StackItem>
                <Button variant="link" isInline onClick={() => void refetchVersions()}>
                  {t('Retry')}
                </Button>
              </StackItem>
            </Stack>
          </Alert>
        </StackItem>
      ) : null}
      <StackItem>
        <OsacForm>
          <SelectField
            name="spec.versionName"
            label={versionOverlay.label}
            fieldId="cluster-version"
            isRequired
            isLoading={versionsLoading}
            isDisabled={!versionOverlay.editable}
            placeholder={t('Select a version')}
            options={versionOptions}
          />
          {isSelectedDeprecated ? (
            <Alert
              variant="warning"
              isInline
              title={t('This version is deprecated and may be removed in a future release.')}
            />
          ) : null}
          <FormSection title={t('Node Sets')} titleElement="h2">
            <ClusterNodeSetsArrayField />
          </FormSection>
        </OsacForm>
      </StackItem>
    </Stack>
  );
};

export default ClusterConfigurationStep;
