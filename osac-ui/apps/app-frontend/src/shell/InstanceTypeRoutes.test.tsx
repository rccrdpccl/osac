import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

vi.mock('@osac/ui-components/components/InstanceType/AdminInstanceTypeListPage', () => ({
  default: () => <h1>Instance types</h1>,
}));

vi.mock('@osac/ui-components/components/InstanceType/AdminInstanceTypeCreatePage', () => ({
  default: () => <h1>Create instance type</h1>,
}));

vi.mock('@osac/ui-components/components/InstanceType/AdminInstanceTypeDetailPage', () => ({
  default: () => <h1>Instance type details</h1>,
}));

import { InstanceTypeRoutes } from './InstanceTypeRoutes';

const renderRoutes = (initialEntry: string) => (
  <MemoryRouter initialEntries={[initialEntry]}>
    <Routes>
      <Route path="/admin/infrastructure/instance-types/*" element={<InstanceTypeRoutes />} />
    </Routes>
  </MemoryRouter>
);

describe('InstanceTypeRoutes', () => {
  it('renders the list page on the index route', () => {
    render(renderRoutes('/admin/infrastructure/instance-types'));

    expect(screen.getByRole('heading', { name: 'Instance types' })).toBeInTheDocument();
  });

  it('renders the create page shell on the create route', () => {
    render(renderRoutes('/admin/infrastructure/instance-types/create'));

    expect(screen.getByRole('heading', { name: 'Create instance type' })).toBeInTheDocument();
  });

  it('renders the detail page shell on the id route', () => {
    render(renderRoutes('/admin/infrastructure/instance-types/gp-small'));

    expect(screen.getByRole('heading', { name: 'Instance type details' })).toBeInTheDocument();
  });
});
