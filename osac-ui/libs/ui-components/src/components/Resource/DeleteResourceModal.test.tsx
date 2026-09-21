import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import DeleteResourceModal from './DeleteResourceModal';

const createMockMutation = (overrides = {}) => ({
  mutate: vi.fn(),
  isPending: false,
  error: null,
  reset: vi.fn(),
  ...overrides,
});

describe('DeleteResourceModal', () => {
  const defaultProps = {
    resourceName: 'my-resource',
    label: 'This will permanently delete the resource.',
    errorLabel: 'Failed to delete resource',
    onClose: vi.fn(),
    onSuccess: vi.fn(),
    variables: 'resource-1',
  };

  beforeEach(() => {
    vi.clearAllMocks();
  });

  it('renders the modal with the confirmation label', () => {
    const mutation = createMockMutation();
    render(<DeleteResourceModal {...defaultProps} mutation={mutation} />);

    expect(screen.getByRole('dialog')).toBeInTheDocument();
    expect(screen.getByText('This will permanently delete the resource.')).toBeInTheDocument();
  });

  it('calls reset and mutate with variables on Delete click', async () => {
    const user = userEvent.setup();
    const mutation = createMockMutation();
    render(<DeleteResourceModal {...defaultProps} mutation={mutation} />);

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    expect(mutation.reset).toHaveBeenCalled();
    expect(mutation.mutate).toHaveBeenCalledWith('resource-1', {
      onSuccess: expect.any(Function) as unknown,
    });
  });

  it('calls onSuccess through handleClosing when mutation succeeds', async () => {
    const user = userEvent.setup();
    const onSuccess = vi.fn();
    const mutation = createMockMutation({
      mutate: vi.fn((_vars: string, opts?: { onSuccess?: () => void }) => {
        opts?.onSuccess?.();
      }),
    });
    render(<DeleteResourceModal {...defaultProps} onSuccess={onSuccess} mutation={mutation} />);

    await user.click(screen.getByRole('button', { name: /^Delete$/i }));

    expect(mutation.reset).toHaveBeenCalled();
    expect(onSuccess).toHaveBeenCalled();
  });

  it('shows error alert when mutation has an error', () => {
    const mutation = createMockMutation({ error: new Error('permission denied') });
    render(<DeleteResourceModal {...defaultProps} mutation={mutation} />);

    expect(screen.getByText('Failed to delete resource')).toBeInTheDocument();
    expect(screen.getByText('permission denied')).toBeInTheDocument();
  });

  it('calls reset and onClose on Cancel click', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const mutation = createMockMutation();
    render(<DeleteResourceModal {...defaultProps} onClose={onClose} mutation={mutation} />);

    await user.click(screen.getByRole('button', { name: /Cancel/i }));

    expect(mutation.reset).toHaveBeenCalled();
    expect(onClose).toHaveBeenCalled();
  });

  it('does not render error alert when there is no error', () => {
    const mutation = createMockMutation();
    render(<DeleteResourceModal {...defaultProps} mutation={mutation} />);

    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });
});
