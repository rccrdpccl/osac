import { describe, expect, it } from 'vitest';

import { InstanceTypeState } from '@osac/types';

import { INSTANCE_TYPE_ACTIVE_LIST_FILTER } from './instance-types';

describe('INSTANCE_TYPE_ACTIVE_LIST_FILTER', () => {
  it('filters instance types to active state using enum integer', () => {
    expect(INSTANCE_TYPE_ACTIVE_LIST_FILTER).toBe(`this.spec.state == ${InstanceTypeState.ACTIVE}`);
  });
});
