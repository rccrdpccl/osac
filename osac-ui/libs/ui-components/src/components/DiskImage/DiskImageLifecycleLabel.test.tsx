import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { DiskImageLifecycle } from '@osac/types';

import DiskImageLifecycleLabel from './DiskImageLifecycleLabel';

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

describe('DiskImageLifecycleLabel', () => {
  it('renders available disk images in green', () => {
    render(<DiskImageLifecycleLabel lifecycle={DiskImageLifecycle.AVAILABLE} />);

    expectLabelColor('Available', 'pf-m-green');
  });

  it('renders deprecated disk images in orange', () => {
    render(<DiskImageLifecycleLabel lifecycle={DiskImageLifecycle.DEPRECATED} />);

    expectLabelColor('Deprecated', 'pf-m-orange');
  });

  it('renders obsolete disk images in grey', () => {
    render(<DiskImageLifecycleLabel lifecycle={DiskImageLifecycle.OBSOLETE} />);

    expectLabelColor('Obsolete');
  });

  it('falls back to unspecified when the lifecycle is missing', () => {
    render(<DiskImageLifecycleLabel />);

    expectLabelColor('Unspecified');
  });

  it('falls back to unspecified when the lifecycle is not a known value', () => {
    render(<DiskImageLifecycleLabel lifecycle={99 as DiskImageLifecycle} />);

    expectLabelColor('Unspecified');
  });
});
