import { describe, expect, it } from 'vitest';

import { camelKeysToSnake, toSnakeCase } from './snakeCase';

describe('toSnakeCase', () => {
  it('converts camelCase to snake_case', () => {
    expect(toSnakeCase('runStrategy')).toBe('run_strategy');
  });

  it('leaves already snake_case strings unchanged', () => {
    expect(toSnakeCase('run_strategy')).toBe('run_strategy');
  });

  it('converts multiple uppercase letters', () => {
    expect(toSnakeCase('restartRequestedAt')).toBe('restart_requested_at');
  });

  it('handles single-word lowercase strings', () => {
    expect(toSnakeCase('spec')).toBe('spec');
  });
});

describe('camelKeysToSnake', () => {
  it('converts object keys to snake_case', () => {
    expect(camelKeysToSnake({ runStrategy: 'Always' })).toEqual({ run_strategy: 'Always' });
  });

  it('recursively converts nested objects', () => {
    expect(camelKeysToSnake({ spec: { runStrategy: 'Always' } })).toEqual({
      spec: { run_strategy: 'Always' },
    });
  });

  it('handles arrays by converting each element', () => {
    expect(camelKeysToSnake([{ runStrategy: 'Always' }, { restartTrigger: 1 }])).toEqual([
      { run_strategy: 'Always' },
      { restart_trigger: 1 },
    ]);
  });

  it('returns primitives unchanged', () => {
    expect(camelKeysToSnake('hello')).toBe('hello');
    expect(camelKeysToSnake(42)).toBe(42);
    expect(camelKeysToSnake(null)).toBe(null);
    expect(camelKeysToSnake(undefined)).toBe(undefined);
  });

  it('handles deeply nested structures', () => {
    const input = { topLevel: { midLevel: { bottomLevel: 'value' } } };
    expect(camelKeysToSnake(input)).toEqual({
      top_level: { mid_level: { bottom_level: 'value' } },
    });
  });
});
