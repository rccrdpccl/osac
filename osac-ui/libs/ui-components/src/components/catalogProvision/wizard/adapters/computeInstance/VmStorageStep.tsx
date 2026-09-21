import { useMemo } from 'react';

import type { ComputeInstanceCatalogItem } from '@osac/types';

import { AdditionalDisksArrayField } from './AdditionalDisksArrayField';
import { useTranslation } from '../../../../../hooks/useTranslation';
import { InputField } from '../../../../Form/InputField';
import OsacForm from '../../../../Form/OsacForm';
import { StorageTierSelectField } from '../../../../Form/StorageTierSelectField';
import { getCatalogFieldOverlay, readCatalogFieldDefinitions } from '../../catalogOverlay';

interface Props {
  catalogItem: ComputeInstanceCatalogItem | null;
}

export const VmStorageStep = ({ catalogItem }: Props) => {
  const { t } = useTranslation();

  const definitions = useMemo(() => readCatalogFieldDefinitions(catalogItem), [catalogItem]);

  const bootDiskOverlay = useMemo(
    () => getCatalogFieldOverlay('spec.boot_disk.size_gib', definitions, t('Boot disk')),
    [definitions, t],
  );
  const storageTierOverlay = useMemo(
    () => getCatalogFieldOverlay('spec.boot_disk.storage_tier', definitions, t('Storage tier')),
    [definitions, t],
  );

  if (!catalogItem) {
    return null;
  }

  return (
    <OsacForm>
      <InputField
        name="spec.bootDisk.sizeGib"
        label={bootDiskOverlay.label}
        fieldId="vm-boot-disk-size"
        type="number"
        isRequired
        helperText={t('Size in GiB')}
        isDisabled={!bootDiskOverlay.editable}
      />
      <StorageTierSelectField
        name="spec.bootDisk.storageTier"
        label={storageTierOverlay.label}
        fieldId="vm-boot-disk-storage-tier"
        isLocked={!storageTierOverlay.editable}
      />
      <AdditionalDisksArrayField />
    </OsacForm>
  );
};
