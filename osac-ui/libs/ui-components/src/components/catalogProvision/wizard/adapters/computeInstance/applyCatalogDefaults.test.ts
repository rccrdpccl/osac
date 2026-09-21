import type { FormikHelpers } from 'formik';
import { describe, expect, it, vi } from 'vitest';

import type { ComputeInstanceCatalogItem } from '@osac/types';

import { applyVmCatalogConfigurationDefaults } from './applyCatalogDefaults';
import type { ComputeInstanceWizardValues } from './fields';
import { tIdentity as t } from '../../../../../test-utils/i18n';

const makeCatalogItem = (
  storageTierDefault: unknown,
  additionalDisksDefault?: unknown,
): ComputeInstanceCatalogItem =>
  ({
    $typeName: 'osac.public.v1.ComputeInstanceCatalogItem',
    id: 'catalog-rhel-9',
    fieldDefinitions: [
      {
        $typeName: 'osac.public.v1.FieldDefinition',
        path: 'spec.boot_disk.storage_tier',
        displayName: 'Storage tier',
        editable: true,
        validationSchema: '',
        ...(storageTierDefault !== undefined ? { default: storageTierDefault } : {}),
      },
      ...(additionalDisksDefault !== undefined
        ? [
            {
              $typeName: 'osac.public.v1.FieldDefinition',
              path: 'spec.additional_disks',
              displayName: 'Additional disks',
              editable: true,
              validationSchema: '',
              default: additionalDisksDefault,
            },
          ]
        : []),
    ],
  }) as unknown as ComputeInstanceCatalogItem;

const protobufNumber = (value: number) => ({ kind: { case: 'numberValue', value } });
const protobufString = (value: string) => ({ kind: { case: 'stringValue', value } });
const protobufStruct = (fields: Record<string, unknown>) => ({
  kind: { case: 'structValue', value: { fields } },
});
const protobufList = (values: unknown[]) => ({ kind: { case: 'listValue', value: { values } } });

describe('applyVmCatalogConfigurationDefaults', () => {
  it('seeds spec.bootDisk.storageTier from the catalog field default', () => {
    const setFieldValue = vi.fn();
    const catalogItem = makeCatalogItem({
      $typeName: 'google.protobuf.Value',
      kind: { case: 'stringValue', value: 'bulk' },
    });

    applyVmCatalogConfigurationDefaults(
      catalogItem,
      { setFieldValue } as unknown as FormikHelpers<ComputeInstanceWizardValues>,
      t,
    );

    expect(setFieldValue).toHaveBeenCalledWith('spec.bootDisk.storageTier', {
      id: '',
      name: 'bulk',
    });
  });

  it('does not set a default when the storage tier field has none', () => {
    const setFieldValue = vi.fn();

    applyVmCatalogConfigurationDefaults(
      makeCatalogItem(undefined),
      { setFieldValue } as unknown as FormikHelpers<ComputeInstanceWizardValues>,
      t,
    );

    expect(setFieldValue).not.toHaveBeenCalledWith('spec.bootDisk.storageTier', expect.anything());
  });

  it('seeds spec.additionalDisks from the catalog additional_disks default', () => {
    const setFieldValue = vi.fn();
    const catalogItem = makeCatalogItem(
      undefined,
      protobufList([
        protobufStruct({
          size_gib: protobufNumber(40),
          storage_tier: protobufString('tier-a'),
        }),
      ]),
    );

    applyVmCatalogConfigurationDefaults(
      catalogItem,
      { setFieldValue } as unknown as FormikHelpers<ComputeInstanceWizardValues>,
      t,
    );

    expect(setFieldValue).toHaveBeenCalledWith('spec.additionalDisks', [
      { sizeGib: '40', storageTier: { id: '', name: 'tier-a' } },
    ]);
  });

  it('does not set a default when the additional_disks field has none', () => {
    const setFieldValue = vi.fn();

    applyVmCatalogConfigurationDefaults(
      makeCatalogItem(undefined),
      { setFieldValue } as unknown as FormikHelpers<ComputeInstanceWizardValues>,
      t,
    );

    expect(setFieldValue).not.toHaveBeenCalledWith('spec.additionalDisks', expect.anything());
  });
});
