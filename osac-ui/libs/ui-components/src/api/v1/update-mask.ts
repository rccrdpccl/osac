import { type DescField, type DescMessage } from '@bufbuild/protobuf';

import { toSnakeCase } from '../../utils/snakeCase';

const isRecursible = (value: unknown): value is Record<string, unknown> =>
  value !== null &&
  typeof value === 'object' &&
  !Array.isArray(value) &&
  !('$typeName' in (value as Record<string, unknown>));

const isOneofField = (value: unknown): value is { case: string; value: unknown } =>
  isRecursible(value) && typeof value.case === 'string' && 'value' in value;

export interface BuildUpdateMaskPathsOptions {
  schema?: DescMessage;
}

const getField = (schema: DescMessage | undefined, key: string): DescField | undefined =>
  schema?.field[key] ??
  schema?.fields.find((field) => field.name === key || field.jsonName === key);

const buildPaths = (
  body: Record<string, unknown>,
  prefix: string,
  schema: DescMessage | undefined,
): string[] => {
  const paths: string[] = [];
  for (const [key, value] of Object.entries(body)) {
    if (isOneofField(value)) {
      const field = getField(schema, value.case);
      const fieldName = field?.name ?? toSnakeCase(value.case);
      const oneofPath = prefix ? `${prefix}.${fieldName}` : fieldName;
      if (isRecursible(value.value) && (field === undefined || field.fieldKind === 'message')) {
        paths.push(...buildPaths(value.value, oneofPath, field?.message));
      } else {
        paths.push(oneofPath);
      }
      continue;
    }
    const field = getField(schema, key);
    const fieldName = field?.name ?? toSnakeCase(key);
    const fullPath = prefix ? `${prefix}.${fieldName}` : fieldName;
    if (isRecursible(value) && (field === undefined || field.fieldKind === 'message')) {
      paths.push(...buildPaths(value, fullPath, field?.message));
    } else {
      paths.push(fullPath);
    }
  }
  return paths;
};

export const buildUpdateMaskPaths = (
  body: Record<string, unknown>,
  { schema }: BuildUpdateMaskPathsOptions = {},
): string[] => buildPaths(body, '', schema);
