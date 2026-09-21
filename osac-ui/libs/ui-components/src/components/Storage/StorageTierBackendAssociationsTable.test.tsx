import { screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import type { BackendAssociation, StorageBackend } from '@osac/types/private';

import { StorageTierBackendAssociationsTable } from './StorageTierBackendAssociationsTable';
import { renderWithProviders } from '../../test-utils/TestProviders';

const makeBackend = (id: string, name: string): StorageBackend =>
  ({ id, metadata: { name } }) as StorageBackend;

const makeAssociation = (overrides: Partial<BackendAssociation> = {}): BackendAssociation =>
  ({
    backendId: 'backend-a',
    maxReadBandwidthMbs: 100,
    maxWriteBandwidthMbs: 80,
    encryptionEnabled: true,
    ...overrides,
  }) as BackendAssociation;

describe('StorageTierBackendAssociationsTable', () => {
  it('renders one row per backend association with resolved name, bandwidth, and encryption', () => {
    const backendsById = new Map([['backend-a', makeBackend('backend-a', 'Fast NVMe')]]);

    renderWithProviders(
      <StorageTierBackendAssociationsTable
        backends={[makeAssociation()]}
        backendsById={backendsById}
      />,
    );

    expect(screen.getByText('Fast NVMe')).toBeInTheDocument();
    expect(screen.getByText('100 MB/s')).toBeInTheDocument();
    expect(screen.getByText('80 MB/s')).toBeInTheDocument();
    expect(screen.getByText('Yes')).toBeInTheDocument();
  });

  it('falls back to the raw backend id when resolution fails', () => {
    renderWithProviders(
      <StorageTierBackendAssociationsTable
        backends={[makeAssociation({ backendId: 'missing-backend' })]}
        backendsById={new Map()}
      />,
    );

    expect(screen.getByText('missing-backend')).toBeInTheDocument();
  });

  it('renders No for a disabled encryption setting', () => {
    renderWithProviders(
      <StorageTierBackendAssociationsTable
        backends={[makeAssociation({ encryptionEnabled: false })]}
        backendsById={new Map()}
      />,
    );

    expect(screen.getByText('No')).toBeInTheDocument();
  });

  it('renders multiple rows for multiple backend associations', () => {
    const backendsById = new Map([
      ['backend-a', makeBackend('backend-a', 'Fast NVMe')],
      ['backend-b', makeBackend('backend-b', 'Bulk HDD')],
    ]);

    renderWithProviders(
      <StorageTierBackendAssociationsTable
        backends={[
          makeAssociation({ backendId: 'backend-a' }),
          makeAssociation({ backendId: 'backend-b' }),
        ]}
        backendsById={backendsById}
      />,
    );

    expect(screen.getByText('Fast NVMe')).toBeInTheDocument();
    expect(screen.getByText('Bulk HDD')).toBeInTheDocument();
    expect(screen.getAllByRole('row')).toHaveLength(3); // header + 2 data rows
  });

  it('renders no data rows for an empty backends array', () => {
    renderWithProviders(
      <StorageTierBackendAssociationsTable backends={[]} backendsById={new Map()} />,
    );

    expect(screen.getAllByRole('row')).toHaveLength(1); // header only
  });
});
