import { create } from '@bufbuild/protobuf';
import { screen, waitFor } from '@testing-library/react';
import { Formik } from 'formik';
import { describe, expect, it } from 'vitest';

import {
  type ComputeInstanceCatalogItem,
  ComputeInstanceTemplateReferenceSchema,
  StorageTierSchema,
  StorageTierState,
} from '@osac/types';

import { createEmptyComputeInstanceValues } from './payload';
import { VmStorageStep } from './VmStorageStep';
import { renderWithProviders } from '../../../../../test-utils/TestProviders';
import {
  type ResourceSelectValue,
  emptyResourceSelectValue,
} from '../../../../Form/resourceSelectValue';

const makeTier = (name: string, displayName: string) =>
  create(StorageTierSchema, {
    id: `id-${name}`,
    metadata: { name, displayName },
    status: { state: StorageTierState.ACTIVE },
  });

const makeCatalogItem = (
  storageTierFieldDefinition?: Record<string, unknown>,
): ComputeInstanceCatalogItem =>
  ({
    $typeName: 'osac.public.v1.ComputeInstanceCatalogItem',
    id: 'catalog-rhel-9',
    metadata: {
      $typeName: 'osac.public.v1.Metadata',
      name: 'catalog-rhel-9',
      annotations: {},
      labels: {},
    },
    title: 'RHEL 9 catalog',
    description: 'RHEL 9 base image',
    template: create(ComputeInstanceTemplateReferenceSchema, {
      id: 'tpl-rhel-9',
      name: 'tpl-rhel-9',
    }),
    published: true,
    fieldDefinitions: storageTierFieldDefinition ? [storageTierFieldDefinition] : [],
  }) as unknown as ComputeInstanceCatalogItem;

const renderStep = (
  catalogItem: ComputeInstanceCatalogItem,
  storageTier: ResourceSelectValue = emptyResourceSelectValue(),
) =>
  renderWithProviders(
    <Formik
      initialValues={{
        ...createEmptyComputeInstanceValues(),
        spec: {
          ...createEmptyComputeInstanceValues().spec,
          bootDisk: { sizeGib: '', storageTier },
        },
      }}
      onSubmit={() => undefined}
    >
      <VmStorageStep catalogItem={catalogItem} />
    </Formik>,
    {
      apiFixtures: {
        publicStorageTiers: [makeTier('other', 'Other'), makeTier('fast', 'Fast SSD')],
      },
    },
  );

// applyVmCatalogConfigurationDefaults (covered separately in applyCatalogDefaults.test.ts) is what
// actually seeds the tier on catalog selection — VmStorageStep only renders whatever value Formik
// already holds, so these tests seed `storageTier` directly to simulate the post-selection state.
describe('VmStorageStep', () => {
  it('shows a catalog-seeded default as editable when the field allows editing', async () => {
    renderStep(
      makeCatalogItem({
        $typeName: 'osac.public.v1.FieldDefinition',
        path: 'spec.boot_disk.storage_tier',
        displayName: 'Storage tier',
        editable: true,
        validationSchema: '',
      }),
      { id: 'id-fast', name: 'fast' },
    );

    await waitFor(() => {
      expect(screen.getByLabelText(/^Storage tier/)).toHaveTextContent('fast');
      expect(screen.getByLabelText(/^Storage tier/)).not.toBeDisabled();
    });
    expect(screen.queryByText('Locked by catalog')).not.toBeInTheDocument();
  });

  it('renders the tier read-only with a lock badge when the catalog locks it', async () => {
    renderStep(
      makeCatalogItem({
        $typeName: 'osac.public.v1.FieldDefinition',
        path: 'spec.boot_disk.storage_tier',
        displayName: 'Storage tier',
        editable: false,
        validationSchema: '',
      }),
      { id: 'id-fast', name: 'fast' },
    );

    await waitFor(() => expect(screen.getByLabelText(/^Storage tier/)).toHaveTextContent('fast'));
    expect(screen.getByText('Locked by catalog')).toBeInTheDocument();
    expect(screen.getByLabelText(/^Storage tier/)).toBeDisabled();
  });

  it('leaves the tier picker editable and unset when the catalog defines no default', async () => {
    renderStep(makeCatalogItem());

    await waitFor(() => expect(screen.getByLabelText(/^Storage tier/)).not.toBeDisabled());
    expect(screen.getByLabelText(/^Storage tier/)).toHaveTextContent('Select a storage tier');
    expect(screen.queryByText('Locked by catalog')).not.toBeInTheDocument();
  });
});

// AdditionalDisksArrayField owns the add/remove/per-row-edit behavior (covered by its own
// AdditionalDisksArrayField.test.tsx) — these tests only confirm it's actually wired into the
// step, alongside the (independently field-tested) boot disk fields.
describe('VmStorageStep — additional disks', () => {
  it('renders the additional-disks array field with no rows initially', () => {
    renderStep(makeCatalogItem());

    expect(screen.getByText('No additional disks added.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add disk' })).toBeInTheDocument();
  });

  it('adding an additional disk does not affect the boot disk fields', async () => {
    const { user } = renderStep(makeCatalogItem(), { id: 'id-fast', name: 'fast' });

    await user.click(screen.getByRole('button', { name: 'Add disk' }));

    await waitFor(() => expect(screen.getAllByLabelText(/^Storage tier/)).toHaveLength(2));
    // Boot disk's picker renders before the additional-disks array field in this step.
    expect(screen.getAllByLabelText(/^Storage tier/)[0]).toHaveTextContent('fast');
  });
});
