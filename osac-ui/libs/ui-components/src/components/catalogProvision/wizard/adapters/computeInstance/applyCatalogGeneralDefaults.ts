import type { FormikHelpers } from 'formik';
import type { TFunction } from 'i18next';

import type { ComputeInstanceCatalogItem } from '@osac/types';

import type { ComputeInstanceWizardValues } from './fields';
import { vmSshPublicKeyWirePath } from './fields';
import {
  getCatalogFieldOverlay,
  overlayDefaultToFormValue,
  readCatalogFieldDefinitions,
} from '../../catalogOverlay';

/** Apply General-step catalog defaults for basics fields (e.g. ssh_public_key) when the catalog defines a default. */
export const applyVmCatalogGeneralDefaults = (
  catalogItem: ComputeInstanceCatalogItem,
  helpers: FormikHelpers<ComputeInstanceWizardValues>,
  t: TFunction,
): void => {
  const definitions = readCatalogFieldDefinitions(catalogItem);
  const sshKeyOverlay = getCatalogFieldOverlay(
    vmSshPublicKeyWirePath,
    definitions,
    t('catalogProvision.vm.fields.sshKey'),
  );

  if (sshKeyOverlay.defaultValue !== undefined) {
    const value = overlayDefaultToFormValue(sshKeyOverlay);
    if (value !== undefined) {
      void helpers.setFieldValue('spec.sshPublicKey', value);
    }
  }
};
