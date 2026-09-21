import { describe, expect, it } from 'vitest';

import { getResourceLifecycleActions } from './getResourceLifecycleActions';

enum TestState {
  UNSPECIFIED = 0,
  ACTIVE = 1,
  DEPRECATED = 2,
  OBSOLETE = 3,
}

const rules = {
  canDeprecate: [TestState.ACTIVE],
  canObsolete: [TestState.ACTIVE, TestState.DEPRECATED],
  canReactivate: [TestState.DEPRECATED, TestState.OBSOLETE],
  canDelete: [TestState.OBSOLETE],
};

describe('getResourceLifecycleActions', () => {
  it('enables only the actions whose rule list includes the current state', () => {
    expect(getResourceLifecycleActions(TestState.ACTIVE, TestState.UNSPECIFIED, rules)).toEqual({
      canDeprecate: true,
      canObsolete: true,
      canReactivate: false,
      canDelete: false,
    });

    expect(getResourceLifecycleActions(TestState.OBSOLETE, TestState.UNSPECIFIED, rules)).toEqual({
      canDeprecate: false,
      canObsolete: false,
      canReactivate: true,
      canDelete: true,
    });
  });

  it('resolves an undefined state to the given unspecified value before evaluating rules', () => {
    expect(getResourceLifecycleActions(undefined, TestState.UNSPECIFIED, rules)).toEqual({
      canDeprecate: false,
      canObsolete: false,
      canReactivate: false,
      canDelete: false,
    });
  });
});
