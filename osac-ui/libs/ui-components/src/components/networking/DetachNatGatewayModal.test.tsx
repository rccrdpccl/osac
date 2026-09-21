import { create } from '@bufbuild/protobuf';
import { Code, ConnectError } from '@connectrpc/connect';
import { screen, waitFor } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { NATGateway, NATGatewaysDeleteRequest } from '@osac/types';
import { NATGatewaysDeleteResponseSchema } from '@osac/types';

import { DetachNatGatewayModal } from './DetachNatGatewayModal';
import type { MockTransportOverrides } from '../../test-utils/createMockConnectTransport';
import { renderWithProviders } from '../../test-utils/TestProviders';

const natGateway = {
  id: 'nat-1',
  metadata: { name: 'nat-egress' },
} as NATGateway;

const renderModal = ({
  onClose = vi.fn(),
  transportOverrides,
}: {
  onClose?: () => void;
  transportOverrides?: MockTransportOverrides;
} = {}) =>
  renderWithProviders(<DetachNatGatewayModal natGateway={natGateway} onClose={onClose} />, {
    apiFixtures: { natGateways: [natGateway] },
    transportOverrides,
  });

describe('DetachNatGatewayModal', () => {
  it('confirms delete by NAT gateway id', async () => {
    const onClose = vi.fn();
    let deleteRequest: NATGatewaysDeleteRequest | undefined;
    const { user } = renderModal({
      onClose,
      transportOverrides: {
        onNatGatewayDelete: (req) => {
          deleteRequest = req;
          return create(NATGatewaysDeleteResponseSchema);
        },
      },
    });

    expect(screen.getByRole('heading', { name: /Delete nat-egress\?/ })).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Delete' }));

    await waitFor(() => {
      expect(deleteRequest?.id).toBe('nat-1');
    });
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  it('shows an inline error and keeps the modal open when delete fails', async () => {
    const onClose = vi.fn();
    const { user } = renderModal({
      onClose,
      transportOverrides: {
        onNatGatewayDelete: () => {
          throw new ConnectError('cannot delete while provisioning', Code.FailedPrecondition);
        },
      },
    });

    await user.click(screen.getByRole('button', { name: 'Delete' }));

    expect(await screen.findByText('Failed to delete NAT gateway')).toBeInTheDocument();
    expect(screen.getByText('cannot delete while provisioning')).toBeInTheDocument();
    expect(screen.getByRole('heading', { name: /Delete nat-egress\?/ })).toBeInTheDocument();
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Delete' })).toBeEnabled();
  });

  it('does not delete when Cancel is clicked', async () => {
    const onClose = vi.fn();
    const onNatGatewayDelete = vi.fn();
    const { user } = renderModal({
      onClose,
      transportOverrides: { onNatGatewayDelete },
    });

    await user.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(onClose).toHaveBeenCalled();
    expect(onNatGatewayDelete).not.toHaveBeenCalled();
  });
});
