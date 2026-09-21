export type ResourceLifecycleActions = {
  canDeprecate: boolean;
  canObsolete: boolean;
  canReactivate: boolean;
  canDelete: boolean;
};

export type ResourceLifecycleActionRules<State extends number> = {
  canDeprecate: State[];
  canObsolete: State[];
  canReactivate: State[];
  canDelete: State[];
};

/** Evaluates a resource's declared lifecycle transition rules against its current state. */
export const getResourceLifecycleActions = <State extends number>(
  state: State | undefined,
  unspecified: State,
  rules: ResourceLifecycleActionRules<State>,
): ResourceLifecycleActions => {
  const resolvedState = state ?? unspecified;

  return {
    canDeprecate: rules.canDeprecate.includes(resolvedState),
    canObsolete: rules.canObsolete.includes(resolvedState),
    canReactivate: rules.canReactivate.includes(resolvedState),
    canDelete: rules.canDelete.includes(resolvedState),
  };
};
