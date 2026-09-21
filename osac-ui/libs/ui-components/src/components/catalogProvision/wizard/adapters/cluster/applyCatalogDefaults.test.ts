import type { FormikHelpers } from 'formik';
import { describe, expect, it, vi } from 'vitest';

import type { ClusterCatalogItem } from '@osac/types';

import { applyClusterCatalogConfigurationDefaults } from './applyCatalogDefaults';
import type { ClusterWizardValues } from './fields';
import { tIdentity as t } from '../../../../../test-utils/i18n';

const makeCatalogItem = (versionDefault: unknown): ClusterCatalogItem =>
  ({
    $typeName: 'osac.public.v1.ClusterCatalogItem',
    id: 'catalog-openshift-4',
    fieldDefinitions: [
      {
        $typeName: 'osac.public.v1.FieldDefinition',
        path: 'version',
        displayName: 'Version',
        editable: true,
        validationSchema: '',
        ...(versionDefault !== undefined ? { default: versionDefault } : {}),
      },
    ],
  }) as unknown as ClusterCatalogItem;

describe('applyClusterCatalogConfigurationDefaults', () => {
  it('unwraps a ClusterVersionReference struct default to the version name', () => {
    const setFieldValue = vi.fn();
    const catalogItem = makeCatalogItem({
      $typeName: 'google.protobuf.Value',
      kind: {
        case: 'structValue',
        value: {
          fields: { name: { kind: { case: 'stringValue', value: '4-17-0' } } },
        },
      },
    });

    applyClusterCatalogConfigurationDefaults(
      catalogItem,
      { setFieldValue } as unknown as FormikHelpers<ClusterWizardValues>,
      t,
    );

    expect(setFieldValue).toHaveBeenCalledWith('spec.versionName', '4-17-0');
  });

  it('does not set a default when the version field has none', () => {
    const setFieldValue = vi.fn();

    applyClusterCatalogConfigurationDefaults(
      makeCatalogItem(undefined),
      { setFieldValue } as unknown as FormikHelpers<ClusterWizardValues>,
      t,
    );

    expect(setFieldValue).not.toHaveBeenCalled();
  });
});
