import { Code, ConnectError } from '@connectrpc/connect';
import { screen, waitFor, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import TenantCreatePage from './TenantCreatePage';
import type { MockTransportOverrides } from '../../../test-utils/createMockConnectTransport';
import { renderWithProviders } from '../../../test-utils/TestProviders';

const mockNavigate = vi.fn();
vi.mock('react-router-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-router-dom')>();
  return {
    ...actual,
    useNavigate: () => mockNavigate,
  };
});

const renderPage = (overrides?: MockTransportOverrides) =>
  renderWithProviders(<TenantCreatePage />, {
    transportOverrides: overrides,
  });

describe('TenantCreatePage', () => {
  beforeEach(() => {
    mockNavigate.mockReset();
  });

  const fillValidForm = async (user: ReturnType<typeof renderPage>['user']) => {
    await user.type(screen.getByRole('textbox', { name: 'Name' }), 'acme-corp');
    await user.click(screen.getByRole('button', { name: 'Add domain' }));
    await user.type(screen.getByRole('textbox', { name: 'Domain 1' }), 'acme.example.com');
  };

  it('renders the page title and form', () => {
    renderPage();

    expect(screen.getByRole('heading', { name: 'Create tenant' })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Name' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Create' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add domain' })).toBeInTheDocument();
  });

  it('renders breadcrumb with link back to tenant list', () => {
    renderPage();

    expect(screen.getByRole('button', { name: 'Tenants' })).toBeInTheDocument();
  });

  it('shows validation error when submitting empty name', async () => {
    const { user } = renderPage();

    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => {
      expect(screen.getByText('Name is required')).toBeInTheDocument();
    });
  });

  it('shows validation error for empty domain', async () => {
    const { user } = renderPage();

    await user.type(screen.getByRole('textbox', { name: 'Name' }), 'acme');
    await user.click(screen.getByRole('button', { name: 'Add domain' }));
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => {
      expect(screen.getByText('Domain is required')).toBeInTheDocument();
    });
  });

  it('shows validation error for invalid domain format', async () => {
    const { user } = renderPage();

    await user.type(screen.getByRole('textbox', { name: 'Name' }), 'acme');
    await user.click(screen.getByRole('button', { name: 'Add domain' }));
    await user.type(screen.getByRole('textbox', { name: 'Domain 1' }), 'not-a-domain');
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => {
      expect(screen.getByText('Must be a valid domain (e.g. example.com)')).toBeInTheDocument();
    });
  });

  it('adds and removes domain fields', async () => {
    const { user } = renderPage();

    await user.click(screen.getByRole('button', { name: 'Add domain' }));
    expect(screen.getByRole('textbox', { name: 'Domain 1' })).toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Add domain' }));
    expect(screen.getByRole('textbox', { name: 'Domain 2' })).toBeInTheDocument();

    const removeButtons = screen.getAllByRole('button', { name: 'Remove domain' });
    await user.click(removeButtons[1]);

    expect(screen.getByRole('textbox', { name: 'Domain 1' })).toBeInTheDocument();
    expect(screen.queryByRole('textbox', { name: 'Domain 2' })).not.toBeInTheDocument();
  });

  it('shows break-glass credential dialog on successful create', async () => {
    const { user } = renderPage();

    await fillValidForm(user);
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => {
      expect(screen.getByText('Break-glass credentials')).toBeInTheDocument();
    });
    expect(
      screen.getByText('Save these credentials now — they cannot be retrieved later.'),
    ).toBeInTheDocument();

    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByDisplayValue('break-glass-admin')).toBeInTheDocument();
    expect(within(dialog).getByDisplayValue('temp-password-123')).toBeInTheDocument();
  });

  it('navigates to tenant detail page after dismissing credential dialog', async () => {
    const { user } = renderPage();

    await fillValidForm(user);
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => {
      expect(screen.getByText('Break-glass credentials')).toBeInTheDocument();
    });

    await user.click(screen.getByRole('button', { name: 'I have saved the credentials' }));

    expect(mockNavigate).toHaveBeenCalledWith('/admin/tenants');
  });

  it('shows error alert when create fails', async () => {
    const { user } = renderPage({
      onTenantCreate: () => {
        throw new ConnectError('Tenant name already exists', Code.AlreadyExists);
      },
    });

    await fillValidForm(user);
    await user.click(screen.getByRole('button', { name: 'Create' }));

    await waitFor(() => {
      expect(screen.getByText('Failed to create tenant')).toBeInTheDocument();
    });
    expect(screen.getByText('Tenant name already exists')).toBeInTheDocument();
  });

  it('navigates back to tenant list on cancel', async () => {
    const { user } = renderPage();

    await user.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(mockNavigate).toHaveBeenCalledWith('/admin/tenants');
  });

  it('navigates back to tenant list via breadcrumb', async () => {
    const { user } = renderPage();

    await user.click(screen.getByRole('button', { name: 'Tenants' }));

    expect(mockNavigate).toHaveBeenCalledWith('/admin/tenants');
  });
});
