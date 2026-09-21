import type { FormikHelpers } from 'formik';
import type { TFunction } from 'i18next';

import type { ClusterCatalogItem } from '@osac/types';

import type { ClusterWizardValues } from './fields';
import { CLUSTER_POD_CIDR_WIRE_PATH, CLUSTER_SERVICE_CIDR_WIRE_PATH } from './fields';
import {
  getCatalogFieldOverlay,
  overlayDefaultToFormValue,
  readCatalogFieldDefinitions,
} from '../../catalogOverlay';

export const applyClusterCatalogNetworkingDefaults = (
  catalogItem: ClusterCatalogItem,
  helpers: FormikHelpers<ClusterWizardValues>,
  t: TFunction,
): void => {
  const definitions = readCatalogFieldDefinitions(catalogItem);
  const podCidrOverlay = getCatalogFieldOverlay(
    CLUSTER_POD_CIDR_WIRE_PATH,
    definitions,
    t('Pod CIDR'),
  );
  const serviceCidrOverlay = getCatalogFieldOverlay(
    CLUSTER_SERVICE_CIDR_WIRE_PATH,
    definitions,
    t('Service CIDR'),
  );

  const podCidr = overlayDefaultToFormValue(podCidrOverlay);
  if (podCidr !== undefined) {
    void helpers.setFieldValue('spec.network.podCidr', podCidr);
  }

  const serviceCidr = overlayDefaultToFormValue(serviceCidrOverlay);
  if (serviceCidr !== undefined) {
    void helpers.setFieldValue('spec.network.serviceCidr', serviceCidr);
  }
};
