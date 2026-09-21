import { screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { StorageBackendState } from '@osac/types/private';

import StorageBackendStatusLabel from './StorageBackendStatusLabel';
import { renderWithProviders } from '../../test-utils/TestProviders';

describe('StorageBackendStatusLabel', () => {
  it('maps READY to ready/Ready', () => {
    renderWithProviders(<StorageBackendStatusLabel state={StorageBackendState.READY} />);
    expect(screen.getByText('Ready')).toBeInTheDocument();
  });

  it('maps UNSPECIFIED to unspecified/Unspecified', () => {
    renderWithProviders(<StorageBackendStatusLabel state={StorageBackendState.UNSPECIFIED} />);
    expect(screen.getByText('Unspecified')).toBeInTheDocument();
  });

  it('maps undefined to unspecified/Unspecified', () => {
    renderWithProviders(<StorageBackendStatusLabel />);
    expect(screen.getByText('Unspecified')).toBeInTheDocument();
  });
});
