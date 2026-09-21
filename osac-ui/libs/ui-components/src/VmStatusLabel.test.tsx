import { screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { ComputeInstanceState } from '@osac/types';

import { initTestI18n } from './test-utils/i18n';
import { renderWithProviders } from './test-utils/TestProviders';
import { VmStatusLabel, resolveVmStatus } from './VmStatusLabel';

describe('resolveVmStatus', () => {
  it('maps running to ready', async () => {
    const i18n = await initTestI18n();
    const t = i18n.t.bind(i18n);
    expect(resolveVmStatus(ComputeInstanceState.RUNNING, t)).toEqual({
      status: 'ready',
      text: 'Running',
    });
  });

  it('maps stopped to failed kind with stopped text', async () => {
    const i18n = await initTestI18n();
    const t = i18n.t.bind(i18n);
    expect(resolveVmStatus(ComputeInstanceState.STOPPED, t)).toEqual({
      status: 'failed',
      text: 'Stopped',
    });
  });

  it('maps paused to grey with paused text', async () => {
    const i18n = await initTestI18n();
    const t = i18n.t.bind(i18n);
    const resolved = resolveVmStatus(ComputeInstanceState.PAUSED, t);
    expect(resolved.status).toBe('unspecified');
    expect(resolved.text).toBe('Paused');
    expect(resolved.color).toBe('grey');
  });

  it('maps transition states to progressing', async () => {
    const i18n = await initTestI18n();
    const t = i18n.t.bind(i18n);
    expect(resolveVmStatus(ComputeInstanceState.STARTING, t).status).toBe('progressing');
    expect(resolveVmStatus(ComputeInstanceState.STOPPING, t).status).toBe('progressing');
    expect(resolveVmStatus(ComputeInstanceState.DELETING, t).status).toBe('progressing');
  });
});

describe('VmStatusLabel', () => {
  it('renders without spinner for starting state', () => {
    renderWithProviders(<VmStatusLabel state={ComputeInstanceState.STARTING} />);
    expect(screen.queryByRole('progressbar')).not.toBeInTheDocument();
    expect(screen.getByText('Starting')).toBeInTheDocument();
  });
});
