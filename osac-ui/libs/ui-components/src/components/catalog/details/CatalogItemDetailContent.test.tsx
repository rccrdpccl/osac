import { render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';

import type { ComputeInstanceCatalogItem } from '@osac/types';

import { CatalogItemDetailContent } from './CatalogItemDetailContent';

vi.mock('../../../hooks/useTranslation', () => ({
  useTranslation: () => ({
    t: (key: string) => key,
  }),
}));

const vmItem: ComputeInstanceCatalogItem = {
  $typeName: 'osac.public.v1.ComputeInstanceCatalogItem',
  id: 'catalog-rhel-9',
  metadata: {
    $typeName: 'osac.public.v1.Metadata',
    displayName: '',
    description: '',
    name: 'catalog-rhel-9',
    annotations: {},
    creator: 'foo',
    labels: { 'run-strategy': 'Always' },
    project: 'foo',
    tenant: 'foo',
    version: 1,
  },
  title: 'RHEL 9 catalog',
  description: 'RHEL 9 base image',
  published: true,
  template: undefined,
  fieldDefinitions: [
    {
      $typeName: 'osac.public.v1.FieldDefinition',
      path: 'cores',
      displayName: 'vCPUs',
      editable: false,
      validationSchema: '',
      default: {
        $typeName: 'google.protobuf.Value',
        kind: { case: 'numberValue', value: 4 },
      },
    },
    {
      $typeName: 'osac.public.v1.FieldDefinition',
      path: 'memory_gib',
      displayName: 'RAM (GiB)',
      editable: false,
      validationSchema: '',
      default: {
        $typeName: 'google.protobuf.Value',
        kind: { case: 'numberValue', value: 8 },
      },
    },
    {
      $typeName: 'osac.public.v1.FieldDefinition',
      path: 'run_strategy',
      displayName: 'run-strategy',
      editable: false,
      validationSchema: '',
      default: {
        $typeName: 'google.protobuf.Value',
        kind: { case: 'stringValue', value: 'Always' },
      },
    },
    {
      $typeName: 'osac.public.v1.FieldDefinition',
      path: 'image.source_ref',
      displayName: 'VM image',
      editable: true,
      validationSchema: '',
      default: {
        $typeName: 'google.protobuf.Value',
        kind: { case: 'stringValue', value: 'quay.io/example/rhel9' },
      },
    },
  ],
  templateParameters: {},
};

describe('CatalogItemDetailContent', () => {
  it('shows drawer-era details including run-strategy configuration and labels', () => {
    render(<CatalogItemDetailContent item={vmItem} />);

    expect(screen.getByText('catalog-rhel-9')).toBeInTheDocument();
    expect(screen.getByText('RHEL 9 base image')).toBeInTheDocument();
    expect(screen.getByText('4 vCPUs')).toBeInTheDocument();
    expect(screen.getByText('8 RAM (GiB)')).toBeInTheDocument();

    // Label key and configuration field display name both surface run-strategy
    expect(screen.getAllByText(/run-strategy/).length).toBeGreaterThanOrEqual(1);
    expect(screen.getAllByText('Always').length).toBeGreaterThanOrEqual(1);
    expect(screen.getByText('VM image')).toBeInTheDocument();
    expect(screen.getByText('quay.io/example/rhel9')).toBeInTheDocument();

    // Resource field display names are not repeated under Configuration defaults
    expect(screen.queryByText('vCPUs')).not.toBeInTheDocument();
    expect(screen.queryByText('RAM (GiB)')).not.toBeInTheDocument();
  });
});
