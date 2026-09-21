import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { VirtualNetworkState } from '@osac/types';

import { VirtualNetworkStatusLabel } from './VirtualNetworkStatusLabel';

describe('VirtualNetworkStatusLabel', () => {
  it('maps PENDING to progressing/Provisioning', () => {
    render(<VirtualNetworkStatusLabel state={VirtualNetworkState.PENDING} />);
    expect(screen.getByText('Provisioning')).toBeInTheDocument();
  });

  it('maps READY to ready/Ready', () => {
    render(<VirtualNetworkStatusLabel state={VirtualNetworkState.READY} />);
    expect(screen.getByText('Ready')).toBeInTheDocument();
  });

  it('maps FAILED to failed/Failed', () => {
    render(<VirtualNetworkStatusLabel state={VirtualNetworkState.FAILED} />);
    expect(screen.getByText('Failed')).toBeInTheDocument();
  });

  it('maps undefined to unspecified/Unknown', () => {
    render(<VirtualNetworkStatusLabel />);
    expect(screen.getByText('Unknown')).toBeInTheDocument();
  });

  it('maps UNSPECIFIED to unspecified/Unknown', () => {
    render(<VirtualNetworkStatusLabel state={VirtualNetworkState.UNSPECIFIED} />);
    expect(screen.getByText('Unknown')).toBeInTheDocument();
  });
});
