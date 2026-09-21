import { screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { ComputeInstance, InstanceType } from '@osac/types';

import VmDetailsSummary from './VmDetailsSummary';
import { renderWithProviders } from '../../../test-utils/TestProviders';

vi.mock('../VmInstanceTypeLabel', () => ({
  VmInstanceTypeLabel: ({
    instanceTypeId,
    instanceType,
  }: {
    instanceTypeId?: string;
    instanceType?: { metadata?: { name?: string } };
  }) => <span>{instanceType?.metadata?.name ?? instanceTypeId ?? '—'}</span>,
}));

const vm = {
  id: 'vm-1',
  spec: { instanceType: { id: 'standard-4-8' } },
  status: { externalIpAddress: '203.0.113.1', internalIpAddress: '10.0.0.5' },
} as ComputeInstance;

const standardInstanceType = {
  id: 'standard-4-8',
  metadata: { name: 'Standard 4 vCPU / 8 GiB' },
} as InstanceType;

const renderSummary = (instance: ComputeInstance = vm, instanceType?: InstanceType) =>
  renderWithProviders(<VmDetailsSummary vm={instance} instanceType={instanceType} />);

describe('VmDetailsSummary', () => {
  it('shows instance type, external IP, and internal IP cards', () => {
    renderSummary(vm, standardInstanceType);

    expect(screen.getByText('Standard 4 vCPU / 8 GiB')).toBeInTheDocument();
    expect(screen.getByText('203.0.113.1')).toBeInTheDocument();
    expect(screen.getByText('10.0.0.5')).toBeInTheDocument();
  });

  it('falls back to raw instance type id when lookup has no data', () => {
    renderSummary();
    expect(screen.getByText('standard-4-8')).toBeInTheDocument();
  });
});
