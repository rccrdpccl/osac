/** Wire compute-instance state strings (PROTO_JSON). */
export const COMPUTE_INSTANCE_STATE = {
  UNSPECIFIED: 'COMPUTE_INSTANCE_STATE_UNSPECIFIED',
  STARTING: 'COMPUTE_INSTANCE_STATE_STARTING',
  RUNNING: 'COMPUTE_INSTANCE_STATE_RUNNING',
  FAILED: 'COMPUTE_INSTANCE_STATE_FAILED',
  DELETING: 'COMPUTE_INSTANCE_STATE_DELETING',
  STOPPING: 'COMPUTE_INSTANCE_STATE_STOPPING',
  STOPPED: 'COMPUTE_INSTANCE_STATE_STOPPED',
  PAUSED: 'COMPUTE_INSTANCE_STATE_PAUSED',
} as const;

export type WireComputeInstanceState =
  (typeof COMPUTE_INSTANCE_STATE)[keyof typeof COMPUTE_INSTANCE_STATE];

const wireStateValues = new Set<string>(Object.values(COMPUTE_INSTANCE_STATE));

export const isKnownWireComputeInstanceState = (state: string): state is WireComputeInstanceState =>
  wireStateValues.has(state);

const hasDeletionTimestamp = (metadata: unknown): boolean => {
  if (!metadata || typeof metadata !== 'object') {
    return false;
  }
  const rec = metadata as Record<string, unknown>;
  const ts = rec.deletionTimestamp ?? rec.deletion_timestamp;
  if (ts == null) {
    return false;
  }
  if (typeof ts === 'string') {
    return ts.trim().length > 0;
  }
  if (typeof ts === 'object') {
    const stamp = ts as Record<string, unknown>;
    return stamp.seconds != null || stamp.nanos != null;
  }
  return false;
};

/** Read status.state from wire JSON (string enum), legacy camelCase, or numeric enum. */
export const readComputeInstanceState = (vm: {
  metadata?: unknown;
  status?: { state?: unknown };
}): string => {
  if (hasDeletionTimestamp(vm.metadata)) {
    return COMPUTE_INSTANCE_STATE.DELETING;
  }

  const state = vm.status?.state;
  if (typeof state === 'string' && state.trim()) {
    const s = state.trim();
    const legacy: Record<string, WireComputeInstanceState> = {
      running: COMPUTE_INSTANCE_STATE.RUNNING,
      stopped: COMPUTE_INSTANCE_STATE.STOPPED,
      paused: COMPUTE_INSTANCE_STATE.PAUSED,
      starting: COMPUTE_INSTANCE_STATE.STARTING,
      stopping: COMPUTE_INSTANCE_STATE.STOPPING,
      deleting: COMPUTE_INSTANCE_STATE.DELETING,
      error: COMPUTE_INSTANCE_STATE.FAILED,
    };
    if (s in legacy) {
      return legacy[s];
    }
    return s;
  }
  if (typeof state === 'number') {
    const byValue: Record<number, WireComputeInstanceState> = {
      0: COMPUTE_INSTANCE_STATE.UNSPECIFIED,
      1: COMPUTE_INSTANCE_STATE.STARTING,
      2: COMPUTE_INSTANCE_STATE.RUNNING,
      3: COMPUTE_INSTANCE_STATE.FAILED,
      4: COMPUTE_INSTANCE_STATE.DELETING,
      5: COMPUTE_INSTANCE_STATE.STOPPING,
      6: COMPUTE_INSTANCE_STATE.STOPPED,
      7: COMPUTE_INSTANCE_STATE.PAUSED,
    };
    return byValue[state] ?? COMPUTE_INSTANCE_STATE.UNSPECIFIED;
  }
  return COMPUTE_INSTANCE_STATE.UNSPECIFIED;
};
