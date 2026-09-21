import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { ResourceLifecycleLabel } from './ResourceLifecycleLabel';

describe('ResourceLifecycleLabel', () => {
  it('renders active in green', () => {
    render(<ResourceLifecycleLabel lifecycle="active" text="Active" />);

    expect(screen.getByText('Active').closest('.pf-v6-c-label')).toHaveClass('pf-m-green');
  });

  it('renders deprecated in orange', () => {
    render(<ResourceLifecycleLabel lifecycle="deprecated" text="Deprecated" />);

    expect(screen.getByText('Deprecated').closest('.pf-v6-c-label')).toHaveClass('pf-m-orange');
  });

  it('renders obsolete in grey', () => {
    render(<ResourceLifecycleLabel lifecycle="obsolete" text="Obsolete" />);

    const label = screen.getByText('Obsolete').closest('.pf-v6-c-label');
    expect(label).not.toHaveClass('pf-m-green');
    expect(label).not.toHaveClass('pf-m-orange');
  });
});
