import { Code, ConnectError } from '@connectrpc/connect';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import StorageTierDeleteConfirmModal from './StorageTierDeleteConfirmModal';
import * as storageTiersApi from '../../api/v1/private/storage-tiers';

vi.mock('../../api/v1/private/storage-tiers', async (importOriginal) => {
  const actual = await importOriginal<typeof storageTiersApi>();
  return {
    ...actual,
    useDeleteStorageTier: vi.fn(),
  };
});

const mockTier = {
  id: 'tier-1',
  metadata: { name: 'fast' },
  spec: { description: '', backends: [] },
};

describe('StorageTierDeleteConfirmModal', () => {
  const mutate = vi.fn();
  const reset = vi.fn();

  beforeEach(() => {
    vi.resetAllMocks();
    vi.mocked(storageTiersApi.useDeleteStorageTier).mockReturnValue({
      mutate,
      reset,
      isPending: false,
      error: null,
    } as unknown as ReturnType<typeof storageTiersApi.useDeleteStorageTier>);
  });

  it('deletes the tier and calls onSuccess', async () => {
    const user = userEvent.setup();
    mutate.mockImplementation((_id: string, options?: { onSuccess?: () => void }) => {
      options?.onSuccess?.();
      return Promise.resolve(undefined);
    });
    const onSuccess = vi.fn();

    render(
      <StorageTierDeleteConfirmModal
        tier={mockTier as never}
        onClose={vi.fn()}
        onSuccess={onSuccess}
      />,
    );

    expect(screen.getByRole('dialog')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => {
      expect(mutate).toHaveBeenCalledWith('tier-1', {
        onSuccess: expect.any(Function) as unknown,
      });
      expect(onSuccess).toHaveBeenCalled();
    });
  });

  it('shows the FAILED_PRECONDITION error verbatim and does not call onSuccess when the tier is referenced by a Tenant', async () => {
    const user = userEvent.setup();
    vi.mocked(storageTiersApi.useDeleteStorageTier).mockReturnValue({
      mutate,
      reset,
      isPending: false,
      error: new ConnectError('Storage tier is referenced by a Tenant', Code.FailedPrecondition),
    } as unknown as ReturnType<typeof storageTiersApi.useDeleteStorageTier>);
    const onSuccess = vi.fn();

    render(
      <StorageTierDeleteConfirmModal
        tier={mockTier as never}
        onClose={vi.fn()}
        onSuccess={onSuccess}
      />,
    );

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => {
      expect(screen.getByText('Storage tier is referenced by a Tenant')).toBeInTheDocument();
    });
    expect(onSuccess).not.toHaveBeenCalled();
  });

  it('calls onClose when Cancel is clicked', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();

    render(
      <StorageTierDeleteConfirmModal
        tier={mockTier as never}
        onClose={onClose}
        onSuccess={vi.fn()}
      />,
    );

    await user.click(screen.getByRole('button', { name: /Cancel/i }));
    expect(onClose).toHaveBeenCalled();
  });
});
