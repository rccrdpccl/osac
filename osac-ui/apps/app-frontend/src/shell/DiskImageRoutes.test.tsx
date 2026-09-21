import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

vi.mock('@osac/ui-components/components/DiskImage/DiskImageListPage', () => ({
  default: () => <h1>Disk images</h1>,
}));

vi.mock('@osac/ui-components/components/DiskImage/DiskImageCreatePage', () => ({
  default: () => <h1>Create disk image</h1>,
}));

vi.mock('@osac/ui-components/components/DiskImage/DiskImageDetailPage', () => ({
  default: () => <h1>Disk image details</h1>,
}));

import { DiskImageRoutes } from './DiskImageRoutes';

const renderRoutes = (initialEntry: string) => (
  <MemoryRouter initialEntries={[initialEntry]}>
    <Routes>
      <Route path="/admin/infrastructure/disk-images/*" element={<DiskImageRoutes />} />
    </Routes>
  </MemoryRouter>
);

describe('DiskImageRoutes', () => {
  it('renders the list page on the index route', () => {
    render(renderRoutes('/admin/infrastructure/disk-images'));

    expect(screen.getByRole('heading', { name: 'Disk images' })).toBeInTheDocument();
  });

  it('renders the create page shell on the create route', () => {
    render(renderRoutes('/admin/infrastructure/disk-images/create'));

    expect(screen.getByRole('heading', { name: 'Create disk image' })).toBeInTheDocument();
  });

  it('renders the detail page shell on the id route', () => {
    render(renderRoutes('/admin/infrastructure/disk-images/rhel-9'));

    expect(screen.getByRole('heading', { name: 'Disk image details' })).toBeInTheDocument();
  });
});
