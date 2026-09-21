import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import AttachExternalIpModal from './AttachExternalIpModal';

const ATTACH_BUTTON_NAME = /Attach/i;

const mutateAsync = vi.fn();
let attachError: Error | null = null;
let poolsError: Error | null = null;
let pools = [
  {
    id: 'pool-1',
    metadata: { name: 'pool-a' },
    status: { available: 2 },
  },
];

vi.mock('../../../api/v1/external-ip', async () => {
  const actual = await vi.importActual('../../../api/v1/external-ip');
  return {
    ...actual,
    useAttachExternalIp: () => ({
      mutateAsync,
      get error() {
        return attachError;
      },
    }),
    useExternalIPPools: () => ({
      data: pools,
      isLoading: false,
      error: poolsError,
    }),
  };
});

const vm = { id: 'vm-1', metadata: { name: 'test-vm' } } as never;

describe('AttachExternalIpModal', () => {
  const mockOnClose = vi.fn();
  const mockOnSuccess = vi.fn();

  beforeEach(() => {
    vi.clearAllMocks();
    attachError = null;
    poolsError = null;
    pools = [
      {
        id: 'pool-1',
        metadata: { name: 'pool-a' },
        status: { available: 2 },
      },
    ];
    mutateAsync.mockResolvedValue({ id: 'attachment-1' });
  });

  it('submits with the auto-selected pool when exactly one pool is available', async () => {
    const user = userEvent.setup();

    render(<AttachExternalIpModal vm={vm} onClose={mockOnClose} onSuccess={mockOnSuccess} />);

    await user.click(screen.getByRole('button', { name: ATTACH_BUTTON_NAME }));

    expect(mutateAsync).toHaveBeenCalledWith({
      computeInstanceId: 'vm-1',
      pool: 'pool-1',
    });
    expect(mockOnSuccess).toHaveBeenCalled();
  });

  it('shows a warning and disables attach when no pools are available', () => {
    pools = [];

    render(<AttachExternalIpModal vm={vm} onClose={mockOnClose} onSuccess={mockOnSuccess} />);

    expect(screen.getByText('No external IP pools available')).toBeInTheDocument();
    expect(
      screen.getByText('Contact your administrator to have an external IP pool provisioned.'),
    ).toBeInTheDocument();
    expect(screen.getByRole('button', { name: ATTACH_BUTTON_NAME })).toBeDisabled();
  });

  it('shows a loading error when pools cannot be retrieved', () => {
    poolsError = new Error('pools unavailable');

    render(<AttachExternalIpModal vm={vm} onClose={mockOnClose} onSuccess={mockOnSuccess} />);

    expect(screen.getByText('Error loading external IP pools')).toBeInTheDocument();
    expect(screen.getByText('pools unavailable')).toBeInTheDocument();
  });

  it('renders an inline error and does not close on attach failure', async () => {
    attachError = new Error('pool exhausted');
    mutateAsync.mockRejectedValue(attachError);
    const user = userEvent.setup();

    render(<AttachExternalIpModal vm={vm} onClose={mockOnClose} onSuccess={mockOnSuccess} />);

    await user.click(screen.getByRole('button', { name: ATTACH_BUTTON_NAME }));

    expect(screen.getByText('pool exhausted')).toBeInTheDocument();
    expect(mockOnSuccess).not.toHaveBeenCalled();
  });
});
