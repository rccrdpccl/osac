import { describe, expect, it } from 'vitest';

import { isKubernetesLabelKey, isKubernetesLabelValue } from './kubernetes-label';

describe('isKubernetesLabelKey', () => {
  it.each([
    'example.com/role',
    'node-role.kubernetes.io/worker',
    'app.kubernetes.io/name',
    'GPU_1',
  ])('accepts valid Kubernetes label key %s', (value) => {
    expect(isKubernetesLabelKey(value)).toBe(true);
  });

  it.each([
    '',
    '/role',
    'example.com/',
    'example.com/a/b',
    'Example.com/role',
    '-example/role',
    'a'.repeat(64),
    `${'a'.repeat(64)}.example.com/role`,
  ])('rejects invalid Kubernetes label key %s', (value) => {
    expect(isKubernetesLabelKey(value)).toBe(false);
  });
});

describe('isKubernetesLabelValue', () => {
  it.each(['', 'gpu', 'A100_80.GB-1', 'a'.repeat(63)])(
    'accepts valid Kubernetes label value %s',
    (value) => {
      expect(isKubernetesLabelValue(value)).toBe(true);
    },
  );

  it.each(['-gpu', 'gpu-', 'gpu/name', 'a'.repeat(64)])(
    'rejects invalid Kubernetes label value %s',
    (value) => {
      expect(isKubernetesLabelValue(value)).toBe(false);
    },
  );
});
