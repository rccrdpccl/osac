import type { AnySchema } from 'yup';
import * as yup from 'yup';

import {
  type CatalogFieldDefinition,
  catalogItemFieldDefinitions,
  compileJsonSchemaPattern,
  fieldDefinitionDefaultToInputString,
  jsonSchemaPatternErrorMessage,
  parseFieldDefinitionDefault,
} from '../catalogFieldDefinition';

export interface CatalogFieldOverlay {
  path: string;
  label: string;
  editable: boolean;
  defaultValue?: unknown;
  validationSchema?: Record<string, unknown>;
}

const wirePathToFormPath = (wirePath: string): string => {
  const withSpec = wirePath.startsWith('spec.') ? wirePath : `spec.${wirePath}`;
  return withSpec
    .split('.')
    .map((segment, index) => {
      if (index === 0) {
        return segment;
      }
      return segment.replace(/_([a-z])/g, (_, letter: string) => letter.toUpperCase());
    })
    .join('.');
};

export const catalogPathToFormPath = (wirePath: string): string => {
  if (wirePath === 'metadata.name') {
    return 'metadata.name';
  }
  if (wirePath.startsWith('metadata.')) {
    return wirePath;
  }
  return wirePathToFormPath(wirePath);
};

/** Catalog field_definitions paths are spec-relative and omit the leading `spec.` segment. */
export const catalogFieldDefinitionWirePaths = (wirePath: string): string[] => {
  const trimmed = wirePath.trim();
  if (!trimmed) {
    return [];
  }
  if (trimmed.startsWith('spec.')) {
    const withoutSpec = trimmed.slice('spec.'.length);
    return withoutSpec === trimmed ? [trimmed] : [trimmed, withoutSpec];
  }
  return [trimmed, `spec.${trimmed}`];
};

export const findCatalogFieldDefinition = (
  wirePath: string,
  definitions: CatalogFieldDefinition[],
): CatalogFieldDefinition | undefined => {
  const candidates = new Set(catalogFieldDefinitionWirePaths(wirePath));
  return definitions.find((entry) => candidates.has(entry.path));
};

export const hasCatalogFieldDefinition = (
  wirePath: string,
  definitions: CatalogFieldDefinition[],
): boolean => findCatalogFieldDefinition(wirePath, definitions) !== undefined;

export const getCatalogFieldOverlay = (
  wirePath: string,
  definitions: CatalogFieldDefinition[],
  defaultLabel: string,
): CatalogFieldOverlay => {
  const def = findCatalogFieldDefinition(wirePath, definitions);
  if (!def) {
    return { path: wirePath, label: defaultLabel, editable: true };
  }
  const defaultRaw =
    def.default !== undefined ? parseFieldDefinitionDefault(def.default) : undefined;
  return {
    path: wirePath,
    label: def.displayName || defaultLabel,
    editable: def.editable,
    ...(defaultRaw !== undefined ? { defaultValue: defaultRaw } : {}),
    ...(def.validationSchema ? { validationSchema: def.validationSchema } : {}),
  };
};

export const readCatalogFieldDefinitions = (catalogItem: unknown): CatalogFieldDefinition[] =>
  catalogItemFieldDefinitions(catalogItem);

const yupFromJsonSchema = (
  schema: Record<string, unknown> | undefined,
  requiredMessage: string,
  fieldLabel?: string,
): AnySchema | undefined => {
  if (!schema) {
    return undefined;
  }
  const type = schema.type;
  if (type === 'integer' || type === 'number') {
    let rule = yup.number().typeError(requiredMessage);
    if (typeof schema.minimum === 'number') {
      rule = rule.min(schema.minimum);
    }
    if (typeof schema.maximum === 'number') {
      rule = rule.max(schema.maximum);
    }
    return rule;
  }
  if (type === 'string') {
    let rule = yup.string();
    if (Array.isArray(schema.enum)) {
      rule = rule.oneOf(schema.enum.map(String));
    }
    if (typeof schema.minLength === 'number') {
      rule = rule.min(schema.minLength);
    }
    if (typeof schema.maxLength === 'number') {
      rule = rule.max(schema.maxLength);
    }
    const patternRegex = compileJsonSchemaPattern(schema.pattern);
    if (patternRegex) {
      const pattern = typeof schema.pattern === 'string' ? schema.pattern : '';
      rule = rule.matches(patternRegex, {
        excludeEmptyString: true,
        message: jsonSchemaPatternErrorMessage(fieldLabel?.trim() || 'This field', pattern),
      });
    }
    return rule;
  }
  if (type === 'boolean') {
    return yup.boolean();
  }
  return undefined;
};

export const mergeCatalogValidation = (
  base: AnySchema,
  overlay: CatalogFieldOverlay | undefined,
  required: boolean,
  requiredMessage: string,
): AnySchema => {
  const catalogRule = yupFromJsonSchema(overlay?.validationSchema, requiredMessage, overlay?.label);
  const rule = catalogRule ?? base;
  if (required) {
    return rule.required(requiredMessage) as AnySchema;
  }
  return rule;
};

export const overlayDefaultToFormValue = (overlay: CatalogFieldOverlay): unknown => {
  if (overlay.defaultValue === undefined) {
    return undefined;
  }
  if (typeof overlay.defaultValue === 'boolean') {
    return overlay.defaultValue;
  }
  return fieldDefinitionDefaultToInputString(overlay.defaultValue);
};

export const setNestedFormValue = (
  target: Record<string, unknown>,
  path: string,
  value: unknown,
): void => {
  const parts = path.split('.');
  let current: Record<string, unknown> = target;
  for (let index = 0; index < parts.length - 1; index += 1) {
    const key = parts[index];
    const next = current[key];
    if (!next || typeof next !== 'object' || Array.isArray(next)) {
      current[key] = {};
    }
    current = current[key] as Record<string, unknown>;
  }
  current[parts[parts.length - 1]] = value;
};

export const getNestedFormValue = (source: Record<string, unknown>, path: string): unknown => {
  return path.split('.').reduce<unknown>((current, key) => {
    if (!current || typeof current !== 'object' || Array.isArray(current)) {
      return undefined;
    }
    return (current as Record<string, unknown>)[key];
  }, source);
};

export const formatReviewScalar = (value: unknown, sensitive = false): string => {
  if (value === undefined || value === null || value === '') {
    return '—';
  }
  if (sensitive && typeof value === 'string' && value.trim()) {
    return 'Provided';
  }
  if (typeof value === 'boolean') {
    return value ? 'true' : 'false';
  }
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'bigint') {
    return String(value);
  }
  if (
    typeof value === 'object' &&
    value !== null &&
    'name' in value &&
    typeof value.name === 'string' &&
    value.name
  ) {
    return value.name;
  }
  return '—';
};

export const formatBootDiskSizeForReview = (value: unknown): string => {
  const formatted = formatReviewScalar(value);
  if (formatted === '—') {
    return formatted;
  }
  return `${formatted} GB`;
};
