import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { InstanceTypeState } from '@osac/types/private';

import InstanceTypeLifecycleLabel from './InstanceTypeLifecycleLabel';

const expectLabelColor = (text: string, colorClass?: string) => {
  const label = screen.getByText(text).closest('.pf-v6-c-label');

  expect(label).not.toBeNull();
  if (colorClass) {
    expect(label).toHaveClass(colorClass);
    return;
  }

  expect(label).not.toHaveClass('pf-m-green');
  expect(label).not.toHaveClass('pf-m-orange');
};

describe('InstanceTypeLifecycleLabel', () => {
  it('renders active instance types in green', () => {
    render(<InstanceTypeLifecycleLabel state={InstanceTypeState.ACTIVE} />);

    expectLabelColor('Active', 'pf-m-green');
  });

  it('renders deprecated instance types in orange', () => {
    render(<InstanceTypeLifecycleLabel state={InstanceTypeState.DEPRECATED} />);

    expectLabelColor('Deprecated', 'pf-m-orange');
  });

  it('renders obsolete instance types in grey', () => {
    render(<InstanceTypeLifecycleLabel state={InstanceTypeState.OBSOLETE} />);

    expectLabelColor('Obsolete');
  });

  it('falls back to unspecified when the state is missing', () => {
    render(<InstanceTypeLifecycleLabel />);

    expectLabelColor('Unspecified');
  });

  it('falls back to unspecified when the state is not one of the known lifecycle states', () => {
    render(<InstanceTypeLifecycleLabel state={99 as InstanceTypeState} />);

    expectLabelColor('Unspecified');
  });
});
