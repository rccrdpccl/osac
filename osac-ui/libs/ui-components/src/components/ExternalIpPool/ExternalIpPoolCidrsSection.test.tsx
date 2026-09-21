import { screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import ExternalIpPoolCidrsSection from './ExternalIpPoolCidrsSection';
import { renderWithProviders } from '../../test-utils/TestProviders';

describe('ExternalIpPoolCidrsSection', () => {
  it('renders a single CIDR without a more button', () => {
    renderWithProviders(<ExternalIpPoolCidrsSection cidrs={['192.168.1.0/24']} />);

    expect(screen.getByRole('heading', { name: 'CIDRs' })).toBeInTheDocument();
    expect(screen.getByText('192.168.1.0/24')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /more/i })).not.toBeInTheDocument();
  });

  it('hides extra CIDRs behind a more button and can collapse them again', async () => {
    const { user } = renderWithProviders(
      <ExternalIpPoolCidrsSection cidrs={['192.168.1.0/24', '10.0.5.0/28', '172.16.0.0/24']} />,
    );

    expect(screen.getByText('192.168.1.0/24')).toBeInTheDocument();
    expect(screen.queryByText('10.0.5.0/28')).not.toBeInTheDocument();
    expect(screen.queryByText('172.16.0.0/24')).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'More' }));

    expect(screen.getByText('10.0.5.0/28')).toBeInTheDocument();
    expect(screen.getByText('172.16.0.0/24')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'More' })).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Show less' }));

    expect(screen.queryByText('10.0.5.0/28')).not.toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'More' })).toBeInTheDocument();
  });

  it('renders an empty state when there are no CIDRs', () => {
    renderWithProviders(<ExternalIpPoolCidrsSection cidrs={[]} />);

    expect(screen.getByText('No CIDRs')).toBeInTheDocument();
  });
});
