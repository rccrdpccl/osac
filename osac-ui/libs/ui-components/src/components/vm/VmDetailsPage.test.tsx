import { Route, Routes } from 'react-router-dom';
import { screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import { VmDetailsPage } from './VmDetailsPage';
import { renderWithProviders } from '../../test-utils/TestProviders';

vi.mock('../../api/v1/compute-instance', () => ({
  useComputeInstance: vi.fn(),
}));

vi.mock('../Resource/ResourceDetailsPageLoading', () => ({
  ResourceDetailsPageLoading: ({ tabLabels }: { tabLabels?: string[] }) => (
    <div>Loading tabs: {tabLabels?.join(', ')}</div>
  ),
}));

vi.mock('./DetailsPage/VmDetails', () => ({
  default: () => <div>VM details loaded</div>,
}));

const { useComputeInstance } = await import('../../api/v1/compute-instance');

const renderPage = () =>
  renderWithProviders(
    <Routes>
      <Route path="/vms/:id" element={<VmDetailsPage />} />
    </Routes>,
    { routerEntries: ['/vms/vm-1'] },
  );

describe('VmDetailsPage', () => {
  it('passes shared VM tab labels to the loading skeleton', () => {
    vi.mocked(useComputeInstance).mockReturnValue({
      data: undefined,
      isLoading: true,
      isError: false,
      error: null,
      refetch: vi.fn(),
    } as unknown as ReturnType<typeof useComputeInstance>);

    renderPage();

    expect(screen.getByText('Loading tabs: Overview, Networking, Console')).toBeInTheDocument();
  });
});
