import { screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

import AdminInstanceTypeCreatePage from './AdminInstanceTypeCreatePage';
import { renderWithProviders } from '../../test-utils/TestProviders';

const mockNavigate = vi.fn();
vi.mock('react-router-dom', async (importOriginal) => {
  const actual = await importOriginal<typeof import('react-router-dom')>();
  return {
    ...actual,
    useNavigate: () => mockNavigate,
  };
});

describe('AdminInstanceTypeCreatePage', () => {
  beforeEach(() => {
    mockNavigate.mockReset();
  });

  it('renders the page title and the create form', () => {
    renderWithProviders(<AdminInstanceTypeCreatePage />);

    expect(screen.getByRole('heading', { name: 'Create instance type' })).toBeInTheDocument();
    expect(screen.getByRole('textbox', { name: 'Name' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Create' })).toBeInTheDocument();
  });

  it('renders breadcrumb with link back to instance type list', () => {
    renderWithProviders(<AdminInstanceTypeCreatePage />);

    expect(screen.getByRole('button', { name: 'Instance types' })).toBeInTheDocument();
  });

  it('navigates back to the instance type list via breadcrumb', async () => {
    const { user } = renderWithProviders(<AdminInstanceTypeCreatePage />);

    await user.click(screen.getByRole('button', { name: 'Instance types' }));

    expect(mockNavigate).toHaveBeenCalledWith('/admin/infrastructure/instance-types');
  });
});
