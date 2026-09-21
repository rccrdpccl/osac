const toSnakeCase = (str: string): string =>
  str.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`);

export const camelKeysToSnake = <T = unknown>(obj: T): T => {
  if (Array.isArray(obj)) {
    return obj.map(camelKeysToSnake) as T;
  }
  if (obj !== null && typeof obj === 'object') {
    return Object.fromEntries(
      Object.entries(obj as Record<string, unknown>).map(([k, v]) => [
        toSnakeCase(k),
        camelKeysToSnake(v),
      ]),
    ) as T;
  }
  return obj;
};

export { toSnakeCase };
