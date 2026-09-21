import { screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { NATGatewayState } from '@osac/types';

import { NatGatewayStatusLabel } from './NatGatewayStatusLabel';
import { renderWithProviders } from '../../test-utils/TestProviders';

describe('NatGatewayStatusLabel', () => {
  it('maps PENDING to progressing/Provisioning', () => {
    renderWithProviders(
      <NatGatewayStatusLabel state={NATGatewayState.NAT_GATEWAY_STATE_PENDING} />,
    );
    expect(screen.getByText('Provisioning')).toBeInTheDocument();
  });

  it('maps READY to ready/Ready', () => {
    renderWithProviders(<NatGatewayStatusLabel state={NATGatewayState.NAT_GATEWAY_STATE_READY} />);
    expect(screen.getByText('Ready')).toBeInTheDocument();
  });

  it('maps FAILED to failed/Failed', () => {
    renderWithProviders(<NatGatewayStatusLabel state={NATGatewayState.NAT_GATEWAY_STATE_FAILED} />);
    expect(screen.getByText('Failed')).toBeInTheDocument();
  });

  it('maps DELETING to progressing/Deleting', () => {
    renderWithProviders(
      <NatGatewayStatusLabel state={NATGatewayState.NAT_GATEWAY_STATE_DELETING} />,
    );
    expect(screen.getByText('Deleting')).toBeInTheDocument();
  });

  it('maps undefined to unspecified/Unknown', () => {
    renderWithProviders(<NatGatewayStatusLabel />);
    expect(screen.getByText('Unknown')).toBeInTheDocument();
  });

  it('maps UNSPECIFIED to unspecified/Unknown', () => {
    renderWithProviders(
      <NatGatewayStatusLabel state={NATGatewayState.NAT_GATEWAY_STATE_UNSPECIFIED} />,
    );
    expect(screen.getByText('Unknown')).toBeInTheDocument();
  });
});
