import { Bullseye, EmptyState, EmptyStateBody, EmptyStateVariant } from '@patternfly/react-core';
import SearchIcon from '@patternfly/react-icons/dist/esm/icons/search-icon';
import { Table, Tbody, Td, Th, Thead, Tr } from '@patternfly/react-table';
import type { TFunction } from 'i18next';

import { Architecture, type DiskImage, GuestOSFamily } from '@osac/types';
import { type Tenant } from '@osac/types/private';
import ResourceNameField from '@osac/ui-components/components/Resource/ResourceNameField.tsx';

import DiskImageActionsMenu from './DiskImageActionsMenu';
import DiskImageLifecycleLabel from './DiskImageLifecycleLabel';
import { useTranslation } from '../../hooks/useTranslation';
import { Timestamp } from '../Primitives/Timestamp';

const NAME_PREVIEW_LENGTH = 32;
const NAME_COLUMN_WIDTH = 20;
const LIFECYCLE_COLUMN_WIDTH = 15;
const GUEST_OS_COLUMN_WIDTH = 15;
const ARCHITECTURE_COLUMN_WIDTH = 20;
const SCOPE_COLUMN_WIDTH = 15;
const CREATED_COLUMN_WIDTH = 15;
const EMPTY_STATE_COLUMN_SPAN = 7;

export const architectureLabels = (t: TFunction): Record<Architecture, string> => ({
  [Architecture.UNSPECIFIED]: t('Unspecified'),
  [Architecture.AMD64]: 'amd64',
  [Architecture.ARM64]: 'arm64',
  [Architecture.S390X]: 's390x',
});

export const guestOsFamilyLabels = (t: TFunction): Record<GuestOSFamily, string> => ({
  [GuestOSFamily.GUEST_OS_FAMILY_UNSPECIFIED]: t('Unspecified'),
  [GuestOSFamily.GUEST_OS_FAMILY_LINUX]: t('Linux'),
  [GuestOSFamily.GUEST_OS_FAMILY_WINDOWS]: t('Windows'),
});

interface DiskImageTableProps {
  diskImages: DiskImage[];
  tenants: Tenant[];
}

const DiskImageTable = ({ diskImages, tenants }: DiskImageTableProps) => {
  const { t } = useTranslation();
  const guestOsFamilyText = guestOsFamilyLabels(t);
  const architectureText = architectureLabels(t);

  return (
    <Table aria-label={t('Disk images')} variant="compact">
      <Thead>
        <Tr>
          <Th width={NAME_COLUMN_WIDTH}>{t('Name')}</Th>
          <Th width={LIFECYCLE_COLUMN_WIDTH}>{t('Lifecycle')}</Th>
          <Th width={GUEST_OS_COLUMN_WIDTH}>{t('Guest OS family')}</Th>
          <Th width={ARCHITECTURE_COLUMN_WIDTH}>{t('Architecture')}</Th>
          <Th width={SCOPE_COLUMN_WIDTH}>{t('Scope')}</Th>
          <Th width={CREATED_COLUMN_WIDTH}>{t('Created')}</Th>
          <Th aria-label={t('Actions')} />
        </Tr>
      </Thead>
      <Tbody>
        {diskImages.length === 0 ? (
          <Tr>
            <Td colSpan={EMPTY_STATE_COLUMN_SPAN}>
              <Bullseye>
                <EmptyState
                  headingLevel="h2"
                  titleText={t('No disk images yet.')}
                  icon={SearchIcon}
                  variant={EmptyStateVariant.sm}
                >
                  <EmptyStateBody>
                    {t('Create a disk image to make it available for provisioning.')}
                  </EmptyStateBody>
                </EmptyState>
              </Bullseye>
            </Td>
          </Tr>
        ) : (
          diskImages.map((diskImage) => {
            const architecture = diskImage.spec?.architecture ?? [];
            const tenantId = diskImage.metadata?.tenant;
            const isGlobal = tenantId === 'shared';
            const tenantName = tenants.find((tenant) => tenant.id === tenantId)?.metadata?.name;

            return (
              <Tr key={diskImage.id}>
                <Td dataLabel={t('Name')} modifier="truncate" width={NAME_COLUMN_WIDTH}>
                  <ResourceNameField
                    resource={diskImage}
                    detailsUrl={`/admin/infrastructure/disk-images/${diskImage.id}`}
                    maxCharsDisplayed={NAME_PREVIEW_LENGTH}
                  />
                </Td>
                <Td dataLabel={t('Lifecycle')} width={LIFECYCLE_COLUMN_WIDTH}>
                  <DiskImageLifecycleLabel lifecycle={diskImage.spec?.lifecycle} />
                </Td>
                <Td dataLabel={t('Guest OS family')} width={GUEST_OS_COLUMN_WIDTH}>
                  {
                    guestOsFamilyText[
                      diskImage.spec?.guestOsFamily ?? GuestOSFamily.GUEST_OS_FAMILY_UNSPECIFIED
                    ]
                  }
                </Td>
                <Td dataLabel={t('Architecture')} width={ARCHITECTURE_COLUMN_WIDTH}>
                  {architecture.length
                    ? architecture
                        .map((value) => architectureText[value] ?? t('Unspecified'))
                        .join(', ')
                    : '—'}
                </Td>
                <Td dataLabel={t('Scope')} width={SCOPE_COLUMN_WIDTH}>
                  {isGlobal ? t('Global') : (tenantName ?? tenantId)}
                </Td>
                <Td dataLabel={t('Created')} width={CREATED_COLUMN_WIDTH}>
                  <Timestamp value={diskImage.metadata?.creationTimestamp} />
                </Td>
                <Td dataLabel={t('Actions')} isActionCell>
                  <DiskImageActionsMenu diskImage={diskImage} />
                </Td>
              </Tr>
            );
          })
        )}
      </Tbody>
    </Table>
  );
};

export default DiskImageTable;
