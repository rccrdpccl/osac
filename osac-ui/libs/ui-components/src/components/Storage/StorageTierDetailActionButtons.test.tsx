import { Route, Routes } from 'react-router-dom';
import { Code, ConnectError } from '@connectrpc/connect';
import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import type { StorageTier } from '@osac/types/private';

import { StorageTierDetailActionButtons } from './StorageTierDetailActionButtons';
import type { MockTransportOverrides } from '../../test-utils/createMockConnectTransport';
import { renderWithProviders } from '../../test-utils/TestProviders';

const tier = {
  id: 'tier-1',
  metadata: { name: 'fast' },
  spec: { description: '', backends: [] },
} as unknown as StorageTier;

const renderAt = (path: string, transportOverrides?: MockTransportOverrides) =>
  renderWithProviders(
    <Routes>
      <Route
        path="/admin/infrastructure/storage/tiers/:id"
        element={<StorageTierDetailActionButtons tier={tier} />}
      />
      <Route path="/admin/infrastructure/storage/tiers" element={<div>navigated-to-list</div>} />
      <Route
        path="/admin/infrastructure/storage/tiers/:id/edit"
        element={<div>navigated-to-edit</div>}
      />
    </Routes>,
    { routerEntries: [path], transportOverrides },
  );

describe('StorageTierDetailActionButtons', () => {
  it('navigates to the edit route when Edit is clicked', async () => {
    const { user } = renderAt('/admin/infrastructure/storage/tiers/tier-1');

    await user.click(screen.getByRole('button', { name: 'Edit' }));

    await waitFor(() => {
      expect(screen.getByText('navigated-to-edit')).toBeInTheDocument();
    });
  });

  it('opens the delete confirmation modal when Delete is clicked', async () => {
    const { user } = renderAt('/admin/infrastructure/storage/tiers/tier-1');

    await user.click(screen.getByRole('button', { name: 'Delete' }));

    expect(screen.getByRole('dialog')).toBeInTheDocument();
  });

  it('navigates to the list route when delete succeeds', async () => {
    const { user } = renderAt('/admin/infrastructure/storage/tiers/tier-1');

    await user.click(screen.getByRole('button', { name: 'Delete' }));
    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => {
      expect(screen.getByText('navigated-to-list')).toBeInTheDocument();
    });
  });

  it('shows a referential-integrity delete error without navigating away', async () => {
    const { user } = renderAt('/admin/infrastructure/storage/tiers/tier-1', {
      onStorageTierDelete: () => {
        throw new ConnectError('Storage tier is referenced by a Tenant', Code.FailedPrecondition);
      },
    });

    await user.click(screen.getByRole('button', { name: 'Delete' }));
    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => {
      expect(screen.getByText('Storage tier is referenced by a Tenant')).toBeInTheDocument();
    });
    expect(screen.queryByText('navigated-to-list')).not.toBeInTheDocument();
  });
});
