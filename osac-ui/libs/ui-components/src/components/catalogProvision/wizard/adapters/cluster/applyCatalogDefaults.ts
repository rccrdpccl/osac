import type { FormikHelpers } from 'formik';
import type { TFunction } from 'i18next';

import type { ClusterCatalogItem } from '@osac/types';

import type { ClusterWizardValues } from './fields';
import { CLUSTER_VERSION_WIRE_PATH } from './fields';
import {
  getCatalogFieldOverlay,
  overlayDefaultToFormValue,
  readCatalogFieldDefinitions,
} from '../../catalogOverlay';

/** The version catalog default is a ClusterVersionReference struct ({ name }); unwrap its name. */
const versionDefaultToName = (defaultValue: unknown): string | undefined => {
  if (defaultValue && typeof defaultValue === 'object' && !Array.isArray(defaultValue)) {
    const name = (defaultValue as { name?: unknown }).name;
    return typeof name === 'string' ? name : undefined;
  }
  return undefined;
};

export const applyClusterCatalogConfigurationDefaults = (
  catalogItem: ClusterCatalogItem,
  helpers: FormikHelpers<ClusterWizardValues>,
  t: TFunction,
): void => {
  const definitions = readCatalogFieldDefinitions(catalogItem);
  const versionOverlay = getCatalogFieldOverlay(
    CLUSTER_VERSION_WIRE_PATH,
    definitions,
    t('Version'),
  );
  const value =
    versionDefaultToName(versionOverlay.defaultValue) ?? overlayDefaultToFormValue(versionOverlay);
  if (value !== undefined) {
    void helpers.setFieldValue('spec.versionName', value);
  }
};
