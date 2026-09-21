import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import ClusterPasswordModal from './ClusterPasswordModal';
import * as clusterApi from '../../../api/v1/cluster';

vi.mock('../../../api/v1/cluster', async (importOriginal) => {
  const actual = await importOriginal<typeof clusterApi>();
  return {
    ...actual,
    useFetchClusterPassword: vi.fn(),
  };
});

const passwordSecretId = 'password-secret-456';

describe('ClusterPasswordModal', () => {
  const retry = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
  });

  const renderModal = (
    overrides: Partial<ReturnType<typeof clusterApi.useFetchClusterPassword>> = {},
    onClose = vi.fn(),
  ) => {
    vi.mocked(clusterApi.useFetchClusterPassword).mockReturnValue({
      isPending: false,
      error: undefined,
      password: undefined,
      retry,
      ...overrides,
    });

    return render(<ClusterPasswordModal passwordSecretId={passwordSecretId} onClose={onClose} />);
  };

  it('fetches password on mount', () => {
    renderModal();

    expect(clusterApi.useFetchClusterPassword).toHaveBeenCalledWith(passwordSecretId);
  });

  it('shows spinner while loading', () => {
    renderModal({ isPending: true });

    expect(screen.getByLabelText(/Loading cluster password/i)).toBeInTheDocument();
  });

  it('displays password in clipboard copy when loaded', () => {
    renderModal({ password: 'super-secret-123' });

    expect(screen.getByDisplayValue('super-secret-123')).toBeInTheDocument();
  });

  it('shows error alert when fetch fails', () => {
    renderModal({ error: new Error('Permission denied') });

    expect(screen.getByText(/Failed to load cluster password/i)).toBeInTheDocument();
    expect(screen.getByText(/Permission denied/i)).toBeInTheDocument();
  });

  it('calls retry when Retry action link is clicked', async () => {
    const user = userEvent.setup();
    renderModal({ error: new Error('Permission denied') });

    await user.click(screen.getByRole('button', { name: /Retry/i }));

    expect(retry).toHaveBeenCalled();
  });

  it('calls onClose when close button is clicked', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    renderModal({}, onClose);

    const closeButtons = screen.getAllByRole('button', { name: /Close/i });
    await user.click(closeButtons[closeButtons.length - 1]);

    expect(onClose).toHaveBeenCalled();
  });

  it('renders modal header with correct title', () => {
    renderModal();

    expect(screen.getByText('Cluster password')).toBeInTheDocument();
  });
});
