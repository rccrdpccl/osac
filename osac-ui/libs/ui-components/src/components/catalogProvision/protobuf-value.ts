const asRecord = (value: unknown): Record<string, unknown> | undefined => {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
};

const isDecodedProtobufValue = (value: unknown): boolean => {
  const kind = asRecord(value)?.kind;
  if (!kind || typeof kind !== 'object') {
    return false;
  }
  const caseName = (kind as { case?: unknown }).case;
  return typeof caseName === 'string' && caseName.length > 0;
};

const parseKindProtobufValue = (value: unknown): unknown => {
  const kind = asRecord(value)?.kind;
  if (!kind || typeof kind !== 'object') {
    return undefined;
  }
  const caseName = (kind as { case?: unknown }).case;
  const caseValue = (kind as { value?: unknown }).value;

  switch (caseName) {
    case 'nullValue':
      return null;
    case 'numberValue':
      return caseValue;
    case 'stringValue':
      return caseValue;
    case 'boolValue':
      return caseValue;
    case 'listValue': {
      const values = asRecord(caseValue)?.values;
      if (!Array.isArray(values)) {
        return undefined;
      }
      return values.map(parseProtobufValueToPlain).filter((entry) => entry !== undefined);
    }
    case 'structValue': {
      const fields = asRecord(caseValue)?.fields;
      if (!fields || typeof fields !== 'object') {
        return undefined;
      }
      const out: Record<string, unknown> = {};
      for (const [key, fieldValue] of Object.entries(fields)) {
        const parsed = parseProtobufValueToPlain(fieldValue);
        if (parsed !== undefined) {
          out[key] = parsed;
        }
      }
      return Object.keys(out).length ? out : undefined;
    }
    default:
      return undefined;
  }
};

const parseWireProtobufValue = (raw: unknown): unknown => {
  if (raw === undefined) {
    return undefined;
  }
  if (raw === null) {
    return null;
  }
  if (typeof raw === 'string' || typeof raw === 'number' || typeof raw === 'boolean') {
    return raw;
  }
  const record = asRecord(raw);
  if (!record) {
    return undefined;
  }
  if ('null_value' in record) {
    return null;
  }
  if ('number_value' in record && typeof record.number_value === 'number') {
    return record.number_value;
  }
  if ('string_value' in record && typeof record.string_value === 'string') {
    return record.string_value;
  }
  if ('bool_value' in record && typeof record.bool_value === 'boolean') {
    return record.bool_value;
  }
  if ('list_value' in record) {
    const list = asRecord(record.list_value);
    const values = list?.values;
    if (Array.isArray(values)) {
      return values.map(parseProtobufValueToPlain).filter((entry) => entry !== undefined);
    }
  }
  if ('struct_value' in record) {
    const struct = asRecord(record.struct_value);
    const fields = struct?.fields;
    if (fields && typeof fields === 'object') {
      const out: Record<string, unknown> = {};
      for (const [key, fieldValue] of Object.entries(fields)) {
        const parsed = parseProtobufValueToPlain(fieldValue);
        if (parsed !== undefined) {
          out[key] = parsed;
        }
      }
      return Object.keys(out).length ? out : undefined;
    }
  }
  return undefined;
};

/**
 * Converts a decoded `google.protobuf.Value` (or wire JSON Value) to plain JSON
 * for catalog field defaults at read time — does not mutate API responses.
 */
const parseProtobufValueToPlain = (value: unknown): unknown => {
  if (value === undefined) {
    return undefined;
  }
  if (value === null) {
    return null;
  }
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  if (isDecodedProtobufValue(value)) {
    return parseKindProtobufValue(value);
  }
  return parseWireProtobufValue(value);
};

export const protobufValueToPlain = (value: unknown): unknown => parseProtobufValueToPlain(value);
