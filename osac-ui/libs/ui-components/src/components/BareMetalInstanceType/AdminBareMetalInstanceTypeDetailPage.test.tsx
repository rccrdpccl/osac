import { Route, Routes } from 'react-router-dom';
import { create } from '@bufbuild/protobuf';
import { screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import {
  BareMetalInstanceTypeSchema,
  type BareMetalInstanceType as PrivateBareMetalInstanceType,
} from '@osac/types/private';

import AdminBareMetalInstanceTypeDetailPage from './AdminBareMetalInstanceTypeDetailPage';
import { renderWithProviders } from '../../test-utils/TestProviders';

const bareMetalInstanceType: PrivateBareMetalInstanceType = create(BareMetalInstanceTypeSchema, {
  id: 'gpu-1',
  metadata: { name: 'gpu-large', creator: 'admin' },
  spec: {
    description: 'GPU-enabled bare metal host',
    hostLabelSelector: { matchLabels: { zone: 'east' } },
    hardware: {
      cpu: { cores: 64, architecture: 'x86_64', model: 'EPYC', threadsPerCore: 2 },
      memory: { totalGb: 256n, type: 'DDR5' },
      accelerators: [{ type: 'GPU', model: 'A100', vendor: 'NVIDIA', memoryGb: 80 }],
      disks: [{ type: 'NVMe', capacityGb: 960n, interface: 'PCIe' }],
      networkPorts: [{ name: 'eth0', role: 'data', type: 'ethernet', speed: '100Gbps' }],
      capabilities: { sriov: 'true' },
    },
  },
});

describe('AdminBareMetalInstanceTypeDetailPage', () => {
  it('renders the instance type hardware details', async () => {
    renderWithProviders(
      <Routes>
        <Route
          path="/admin/infrastructure/baremetal-instance-types/:id"
          element={<AdminBareMetalInstanceTypeDetailPage />}
        />
      </Routes>,
      {
        apiFixtures: { privateBaremetalInstanceTypes: [bareMetalInstanceType] },
        routerEntries: ['/admin/infrastructure/baremetal-instance-types/gpu-1'],
      },
    );

    expect(await screen.findByRole('heading', { name: 'gpu-large' })).toBeInTheDocument();
    expect(screen.getByText('zone=east')).toBeInTheDocument();
    expect(screen.getByText('64')).toBeInTheDocument();
    expect(screen.getByText('256 GB · DDR5')).toBeInTheDocument();
    expect(screen.getByText('GPU · A100 · NVIDIA · 80 GB')).toBeInTheDocument();
    expect(screen.getByText('NVMe · 960 GB · PCIe')).toBeInTheDocument();
    expect(screen.getByText('eth0 · data · ethernet · 100Gbps')).toBeInTheDocument();
    expect(screen.getByText('sriov=true')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Edit' })).toBeInTheDocument();
  });
});
