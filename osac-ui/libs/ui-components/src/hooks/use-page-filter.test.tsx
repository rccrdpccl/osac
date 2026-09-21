import { MemoryRouter, useLocation } from 'react-router-dom';
import { act, renderHook } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import { serializePageFilter, useArrayPageFilter, usePageFilter } from './use-page-filter';

type Fruit = 'apple' | 'banana' | 'cherry';
const isFruit = (val: string): val is Fruit =>
  val === 'apple' || val === 'banana' || val === 'cherry';

const makeWrapper = (initialEntries: string[] = ['/']) => {
  const Wrapper = ({ children }: { children: React.ReactNode }) => (
    <MemoryRouter initialEntries={initialEntries}>{children}</MemoryRouter>
  );
  Wrapper.displayName = 'Wrapper';
  return Wrapper;
};

describe('serializePageFilter', () => {
  it('returns null for an empty array', () => {
    expect(serializePageFilter([])).toBeNull();
  });

  it('joins a single value', () => {
    expect(serializePageFilter(['apple'])).toBe('apple');
  });

  it('joins multiple values with commas', () => {
    expect(serializePageFilter(['apple', 'banana'])).toBe('apple,banana');
  });
});

describe('useArrayPageFilter', () => {
  it('returns an empty array when the param is absent', () => {
    const { result } = renderHook(() => useArrayPageFilter<Fruit>('kind', isFruit), {
      wrapper: makeWrapper(['/']),
    });

    expect(result.current[0]).toEqual([]);
  });

  it('parses valid comma-separated values from the URL', () => {
    const { result } = renderHook(() => useArrayPageFilter<Fruit>('kind', isFruit), {
      wrapper: makeWrapper(['/?kind=apple,banana']),
    });

    expect(result.current[0]).toEqual(['apple', 'banana']);
  });

  it('trims whitespace around values', () => {
    const { result } = renderHook(() => useArrayPageFilter<Fruit>('kind', isFruit), {
      wrapper: makeWrapper(['/?kind=%20apple%20,%20banana%20']),
    });

    expect(result.current[0]).toEqual(['apple', 'banana']);
  });

  it('drops values that fail the type guard', () => {
    const { result } = renderHook(() => useArrayPageFilter<Fruit>('kind', isFruit), {
      wrapper: makeWrapper(['/?kind=apple,pear,banana']),
    });

    expect(result.current[0]).toEqual(['apple', 'banana']);
  });

  it('deduplicates repeated values', () => {
    const { result } = renderHook(() => useArrayPageFilter<Fruit>('kind', isFruit), {
      wrapper: makeWrapper(['/?kind=apple,apple,banana']),
    });

    expect(result.current[0]).toEqual(['apple', 'banana']);
  });

  it('adds a value when toggled on', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [filter, setFilter] = useArrayPageFilter<Fruit>('kind', isFruit);
        return { filter, setFilter, search: location.search };
      },
      { wrapper: makeWrapper(['/']) },
    );

    act(() => {
      result.current.setFilter('apple');
    });

    expect(result.current.filter).toEqual(['apple']);
    expect(result.current.search).toBe('?kind=apple');
  });

  it('removes a value when toggled off', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [filter, setFilter] = useArrayPageFilter<Fruit>('kind', isFruit);
        return { filter, setFilter, search: location.search };
      },
      { wrapper: makeWrapper(['/?kind=apple,banana']) },
    );

    act(() => {
      result.current.setFilter('apple');
    });

    expect(result.current.filter).toEqual(['banana']);
    expect(result.current.search).toBe('?kind=banana');
  });

  it('removes the param entirely when the last value is toggled off', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [filter, setFilter] = useArrayPageFilter<Fruit>('kind', isFruit);
        return { filter, setFilter, search: location.search };
      },
      { wrapper: makeWrapper(['/?kind=apple']) },
    );

    act(() => {
      result.current.setFilter('apple');
    });

    expect(result.current.filter).toEqual([]);
    expect(result.current.search).toBe('');
  });

  it('preserves unrelated search params when toggling', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [filter, setFilter] = useArrayPageFilter<Fruit>('kind', isFruit);
        return { filter, setFilter, search: location.search };
      },
      { wrapper: makeWrapper(['/?other=keep']) },
    );

    act(() => {
      result.current.setFilter('apple');
    });

    const params = new URLSearchParams(result.current.search);
    expect(params.get('other')).toBe('keep');
    expect(params.get('kind')).toBe('apple');
  });

  it('supports multiple independent filter keys', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [kinds, setKind] = useArrayPageFilter<Fruit>('kind', isFruit);
        const [others, setOther] = useArrayPageFilter<Fruit>('other', isFruit);
        return { kinds, setKind, others, setOther, search: location.search };
      },
      { wrapper: makeWrapper(['/']) },
    );

    act(() => {
      result.current.setKind('apple');
    });
    act(() => {
      result.current.setOther('banana');
    });

    expect(result.current.kinds).toEqual(['apple']);
    expect(result.current.others).toEqual(['banana']);
  });

  it('composes two distinct toggles fired before a re-render', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [filter, setFilter] = useArrayPageFilter<Fruit>('kind', isFruit);
        return { filter, setFilter, search: location.search };
      },
      { wrapper: makeWrapper(['/']) },
    );

    act(() => {
      result.current.setFilter('apple');
      result.current.setFilter('banana');
    });

    expect(result.current.filter).toEqual(['apple', 'banana']);
    expect(result.current.search).toBe('?kind=apple%2Cbanana');
  });
});

describe('usePageFilter', () => {
  it('returns an empty string when the param is absent', () => {
    const { result } = renderHook(() => usePageFilter('q'), {
      wrapper: makeWrapper(['/']),
    });

    expect(result.current[0]).toBe('');
  });

  it('reads the current value from the URL', () => {
    const { result } = renderHook(() => usePageFilter('q'), {
      wrapper: makeWrapper(['/?q=hello']),
    });

    expect(result.current[0]).toBe('hello');
  });

  it('sets the value into the URL', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [value, setValue] = usePageFilter('q');
        return { value, setValue, search: location.search };
      },
      { wrapper: makeWrapper(['/']) },
    );

    act(() => {
      result.current.setValue('hello');
    });

    expect(result.current.value).toBe('hello');
    expect(result.current.search).toBe('?q=hello');
  });

  it('removes the param when set to an empty string', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [value, setValue] = usePageFilter('q');
        return { value, setValue, search: location.search };
      },
      { wrapper: makeWrapper(['/?q=hello']) },
    );

    act(() => {
      result.current.setValue('');
    });

    expect(result.current.value).toBe('');
    expect(result.current.search).toBe('');
  });

  it('removes the param when set to whitespace only', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [value, setValue] = usePageFilter('q');
        return { value, setValue, search: location.search };
      },
      { wrapper: makeWrapper(['/?q=hello']) },
    );

    act(() => {
      result.current.setValue('   ');
    });

    expect(result.current.value).toBe('');
    expect(result.current.search).toBe('');
  });

  it('stores the raw (untrimmed) value when it has non-whitespace content', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [value, setValue] = usePageFilter('q');
        return { value, setValue, search: location.search };
      },
      { wrapper: makeWrapper(['/']) },
    );

    act(() => {
      result.current.setValue(' hello ');
    });

    expect(result.current.value).toBe(' hello ');
  });

  it('preserves unrelated search params when setting', () => {
    const { result } = renderHook(
      () => {
        const location = useLocation();
        const [value, setValue] = usePageFilter('q');
        return { value, setValue, search: location.search };
      },
      { wrapper: makeWrapper(['/?other=keep']) },
    );

    act(() => {
      result.current.setValue('hello');
    });

    const params = new URLSearchParams(result.current.search);
    expect(params.get('other')).toBe('keep');
    expect(params.get('q')).toBe('hello');
  });
});
