import { type TFunction } from 'i18next';
import { describe, expect, it } from 'vitest';

import {
  VM_DETAIL_CONSOLE_TAB_ID,
  VM_DETAIL_NETWORKING_TAB_ID,
  VM_DETAIL_OVERVIEW_TAB_ID,
  getVmDetailTabLabels,
} from './vm-detail-tabs';

describe('vm-detail-tabs', () => {
  it('exports stable tab content id constants', () => {
    expect(VM_DETAIL_OVERVIEW_TAB_ID).toBe('vm-detail-overview');
    expect(VM_DETAIL_NETWORKING_TAB_ID).toBe('vm-detail-networking');
    expect(VM_DETAIL_CONSOLE_TAB_ID).toBe('vm-detail-console');
  });

  it('returns Overview, Networking, and Console tab labels', () => {
    const t = ((key: string) => key) as TFunction;

    expect(getVmDetailTabLabels(t)).toEqual(['Overview', 'Networking', 'Console']);
  });
});
