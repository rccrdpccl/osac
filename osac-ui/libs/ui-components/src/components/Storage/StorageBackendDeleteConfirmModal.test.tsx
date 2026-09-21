import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import StorageBackendDeleteConfirmModal from './StorageBackendDeleteConfirmModal';
import * as storageBackendsApi from '../../api/v1/private/storage-backends';

vi.mock('../../api/v1/private/storage-backends', async (importOriginal) => {
  const actual = await importOriginal<typeof storageBackendsApi>();
  return {
    ...actual,
    useDeleteStorageBackend: vi.fn(),
  };
});

const mockBackend = {
  id: 'backend-1',
  metadata: { name: 'vast-prod' },
  spec: { provider: 'vast', endpoint: 'vast.example.com' },
};

describe('StorageBackendDeleteConfirmModal', () => {
  const mutate = vi.fn();
  const reset = vi.fn();

  beforeEach(() => {
    vi.resetAllMocks();
    vi.mocked(storageBackendsApi.useDeleteStorageBackend).mockReturnValue({
      mutate,
      reset,
      isPending: false,
      error: null,
    } as unknown as ReturnType<typeof storageBackendsApi.useDeleteStorageBackend>);
  });

  it('deletes the backend and calls onSuccess', async () => {
    const user = userEvent.setup();
    mutate.mockImplementation((_id: string, options?: { onSuccess?: () => void }) => {
      options?.onSuccess?.();
      return Promise.resolve(undefined);
    });
    const onSuccess = vi.fn();

    render(
      <StorageBackendDeleteConfirmModal
        backend={mockBackend as never}
        onClose={vi.fn()}
        onSuccess={onSuccess}
      />,
    );

    expect(screen.getByRole('dialog')).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => {
      expect(mutate).toHaveBeenCalledWith('backend-1', {
        onSuccess: expect.any(Function) as unknown,
      });
      expect(onSuccess).toHaveBeenCalled();
    });
  });

  it('shows the FAILED_PRECONDITION error verbatim and does not call onSuccess', async () => {
    const user = userEvent.setup();
    vi.mocked(storageBackendsApi.useDeleteStorageBackend).mockReturnValue({
      mutate,
      reset,
      isPending: false,
      error: new Error('[failed_precondition] backend is referenced by an active storage tier'),
    } as unknown as ReturnType<typeof storageBackendsApi.useDeleteStorageBackend>);
    const onSuccess = vi.fn();

    render(
      <StorageBackendDeleteConfirmModal
        backend={mockBackend as never}
        onClose={vi.fn()}
        onSuccess={onSuccess}
      />,
    );

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => {
      expect(
        screen.getByText(/backend is referenced by an active storage tier/i),
      ).toBeInTheDocument();
    });
    expect(onSuccess).not.toHaveBeenCalled();
  });

  it('calls onClose when Cancel is clicked', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();

    render(
      <StorageBackendDeleteConfirmModal
        backend={mockBackend as never}
        onClose={onClose}
        onSuccess={vi.fn()}
      />,
    );

    await user.click(screen.getByRole('button', { name: /Cancel/i }));
    expect(onClose).toHaveBeenCalled();
  });
});
