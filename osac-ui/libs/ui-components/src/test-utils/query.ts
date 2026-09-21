import type { UseMutationResult, UseQueryResult } from '@tanstack/react-query';

export const mockQueryResult = <T>(
  overrides: Partial<UseQueryResult<T, unknown>> = {},
): UseQueryResult<T, unknown> =>
  ({
    data: undefined,
    isLoading: false,
    error: null,
    ...overrides,
  }) as UseQueryResult<T, unknown>;

// Constraint requires `any` — UseMutationResult type params are contravariant
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyMutationResult = UseMutationResult<any, any, any, any>;

export const mockMutationResult = <T extends AnyMutationResult>(overrides: Partial<T> = {}): T =>
  ({
    mutateAsync: overrides.mutateAsync,
    ...overrides,
  }) as T;
