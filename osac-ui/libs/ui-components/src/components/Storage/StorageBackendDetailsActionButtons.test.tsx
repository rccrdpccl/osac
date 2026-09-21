import { MemoryRouter } from 'react-router-dom';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import type { StorageBackend } from '@osac/types/private';

import StorageBackendDetailsActionButtons from './StorageBackendDetailsActionButtons';
import * as storageBackendsApi from '../../api/v1/private/storage-backends';

vi.mock('../../api/v1/private/storage-backends', async (importOriginal) => {
  const actual = await importOriginal<typeof storageBackendsApi>();
  return {
    ...actual,
    useDeleteStorageBackend: vi.fn(),
  };
});

const mockNavigate = vi.fn();
vi.mock('react-router-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-router-dom')>();
  return {
    ...actual,
    useNavigate: () => mockNavigate,
  };
});

const mockBackend = {
  id: 'backend-1',
  metadata: { name: 'vast-prod' },
  spec: { provider: 'vast', endpoint: 'vast.example.com' },
} as StorageBackend;

describe('StorageBackendDetailsActionButtons', () => {
  const mutate = vi.fn();
  const reset = vi.fn();

  beforeEach(() => {
    mockNavigate.mockReset();
    vi.mocked(storageBackendsApi.useDeleteStorageBackend).mockReturnValue({
      mutate,
      reset,
      isPending: false,
      error: null,
    } as unknown as ReturnType<typeof storageBackendsApi.useDeleteStorageBackend>);
  });

  const renderButtons = () =>
    render(
      <MemoryRouter>
        <StorageBackendDetailsActionButtons backend={mockBackend} />
      </MemoryRouter>,
    );

  it('renders Edit and Delete buttons', () => {
    renderButtons();

    expect(screen.getByRole('button', { name: /^Edit$/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /^Delete$/i })).toBeInTheDocument();
  });

  it('navigates to the edit route when Edit is clicked', async () => {
    const user = userEvent.setup();
    renderButtons();

    await user.click(screen.getByRole('button', { name: /^Edit$/i }));

    expect(mockNavigate).toHaveBeenCalledWith(
      '/admin/infrastructure/storage/backends/backend-1/edit',
    );
  });

  it('opens the delete confirmation dialog when Delete is clicked', async () => {
    const user = userEvent.setup();
    renderButtons();

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    expect(screen.getByRole('dialog')).toBeInTheDocument();
  });

  it('navigates to the backends list after a successful delete', async () => {
    const user = userEvent.setup();
    mutate.mockImplementation((_id: string, options?: { onSuccess?: () => void }) => {
      options?.onSuccess?.();
    });
    renderButtons();

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));
    await user.click(within(screen.getByRole('dialog')).getByRole('button', { name: /^Delete$/i }));

    expect(mockNavigate).toHaveBeenCalledWith('/admin/infrastructure/storage/backends');
  });
});
