import { create } from '@bufbuild/protobuf';
import { Code, ConnectError } from '@connectrpc/connect';
import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { type DiskImage, DiskImageSchema, DiskImagesDeleteResponseSchema } from '@osac/types';

import DiskImageDeleteConfirmModal from './DiskImageDeleteConfirmModal';
import { renderWithProviders } from '../../test-utils/TestProviders';

const mockDiskImage: DiskImage = create(DiskImageSchema, {
  id: 'disk-1',
  metadata: { name: 'fedora-41' },
});

describe('DiskImageDeleteConfirmModal', () => {
  it('deletes the disk image and calls onSuccess', async () => {
    let deleteCalled = false;
    const onSuccess = vi.fn();
    const { user } = renderWithProviders(
      <DiskImageDeleteConfirmModal
        diskImage={mockDiskImage}
        onClose={vi.fn()}
        onSuccess={onSuccess}
      />,
      {
        transportOverrides: {
          onDiskImageDelete: (req) => {
            deleteCalled = true;
            expect(req.id).toBe('disk-1');
            return create(DiskImagesDeleteResponseSchema);
          },
        },
      },
    );

    expect(screen.getByRole('dialog')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => expect(onSuccess).toHaveBeenCalled());
    expect(deleteCalled).toBe(true);
  });

  it('calls onClose when Cancel is clicked', async () => {
    const onClose = vi.fn();
    const { user } = renderWithProviders(
      <DiskImageDeleteConfirmModal
        diskImage={mockDiskImage}
        onClose={onClose}
        onSuccess={vi.fn()}
      />,
    );

    await user.click(screen.getByRole('button', { name: /Cancel/i }));
    expect(onClose).toHaveBeenCalled();
  });

  it('shows an inline error and does not call onSuccess when delete fails with FailedPrecondition', async () => {
    const onSuccess = vi.fn();
    const { user } = renderWithProviders(
      <DiskImageDeleteConfirmModal
        diskImage={mockDiskImage}
        onClose={vi.fn()}
        onSuccess={onSuccess}
      />,
      {
        transportOverrides: {
          onDiskImageDelete: () => {
            throw new ConnectError(
              'disk image is referenced by ComputeInstance vm-1',
              Code.FailedPrecondition,
            );
          },
        },
      },
    );

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    await waitFor(() => {
      expect(screen.getByText('Failed to delete disk image')).toBeInTheDocument();
    });
    expect(
      screen.getByText('disk image is referenced by ComputeInstance vm-1'),
    ).toBeInTheDocument();
    expect(screen.getByRole('dialog')).toBeInTheDocument();
    expect(onSuccess).not.toHaveBeenCalled();
  });
});
