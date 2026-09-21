import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { StorageTierState } from '@osac/types/private';

import { StorageTierStatusLabel } from './StorageTierStatusLabel';

describe('StorageTierStatusLabel', () => {
  it('maps ACTIVE to ready/Active', () => {
    render(<StorageTierStatusLabel state={StorageTierState.ACTIVE} />);
    expect(screen.getByText('Active')).toBeInTheDocument();
  });

  it('maps undefined to unspecified/Unspecified', () => {
    render(<StorageTierStatusLabel />);
    expect(screen.getByText('Unspecified')).toBeInTheDocument();
  });

  it('maps UNSPECIFIED to unspecified/Unspecified', () => {
    render(<StorageTierStatusLabel state={StorageTierState.UNSPECIFIED} />);
    expect(screen.getByText('Unspecified')).toBeInTheDocument();
  });
});
