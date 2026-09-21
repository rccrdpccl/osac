import { screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { ComputeInstance } from '@osac/types';

import VmNetworkingTab from './VmNetworkingTab';
import { renderWithProviders } from '../../../test-utils/TestProviders';

vi.mock('./useVmNetworkAttachmentRows', () => ({
  useVmNetworkAttachmentRows: vi.fn(),
}));

const { useVmNetworkAttachmentRows } = await import('./useVmNetworkAttachmentRows');

const renderTab = (vm: ComputeInstance) => renderWithProviders(<VmNetworkingTab vm={vm} />);

describe('VmNetworkingTab', () => {
  it('renders resolved networking names', () => {
    vi.mocked(useVmNetworkAttachmentRows).mockReturnValue([
      {
        virtualNetwork: 'prod-vn',
        subnet: 'prod-subnet',
        securityGroups: 'web-sg, default-sg',
      },
    ]);

    const vm = {
      id: 'vm-1',
      spec: {
        networkAttachments: [
          {
            subnet: { id: 'subnet-1' },
            securityGroups: [{ id: 'sg-1' }, { id: 'sg-2' }],
          },
        ],
      },
    } as ComputeInstance;

    renderTab(vm);

    expect(screen.getByText('prod-vn')).toBeInTheDocument();
    expect(screen.getByText('prod-subnet')).toBeInTheDocument();
    expect(screen.getByText('web-sg, default-sg')).toBeInTheDocument();
  });

  it('shows empty state when there are no attachments', () => {
    vi.mocked(useVmNetworkAttachmentRows).mockReturnValue([]);

    renderTab({ id: 'vm-1', spec: {} } as ComputeInstance);
    expect(screen.getByText('No virtual networks configured.')).toBeInTheDocument();
  });
});
