import { describe, expect, it } from 'vitest';

import { formatHttpApiErrorMessage, parseHttpErrorBody } from './error';

describe('parseHttpErrorBody', () => {
  it('extracts message from gRPC-gateway JSON errors', () => {
    expect(
      parseHttpErrorBody(
        `{"code":3, "message":"field 'user_data' is required but no value was provided and no default is defined"}`,
      ),
    ).toBe("field 'user_data' is required but no value was provided and no default is defined");
  });

  it('returns plain text bodies unchanged', () => {
    expect(parseHttpErrorBody('upstream unavailable')).toBe('upstream unavailable');
  });
});

describe('formatHttpApiErrorMessage', () => {
  it('returns only the parsed message when the body is JSON', () => {
    expect(
      formatHttpApiErrorMessage(
        400,
        `{"code":3,"message":"field 'boot_disk.size_gib' is required but no value was provided and no default is defined"}`,
      ),
    ).toBe(
      "field 'boot_disk.size_gib' is required but no value was provided and no default is defined",
    );
  });

  it('returns plain text bodies unchanged', () => {
    expect(formatHttpApiErrorMessage(502, 'Bad Gateway', 'Bad Gateway')).toBe('Bad Gateway');
  });

  it('falls back to status when the body is empty', () => {
    expect(formatHttpApiErrorMessage(502, '', 'Bad Gateway')).toBe('API 502: Bad Gateway');
  });
});
