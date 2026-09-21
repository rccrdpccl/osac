import { describe, expect, it } from 'vitest';

import { BareMetalInstanceTypeSchema } from '@osac/types/private';

import { buildUpdateMaskPaths } from './update-mask';

describe('buildUpdateMaskPaths', () => {
  it('converts a single camelCase key to snake_case', () => {
    expect(buildUpdateMaskPaths({ runStrategy: 'Always' })).toEqual(['run_strategy']);
  });

  it('builds nested paths', () => {
    expect(buildUpdateMaskPaths({ spec: { runStrategy: 'Always' } })).toEqual([
      'spec.run_strategy',
    ]);
  });

  it('handles multiple keys at the same level', () => {
    const paths = buildUpdateMaskPaths({ spec: { runStrategy: 'Always' }, status: { state: 1 } });
    expect(paths).toEqual(['spec.run_strategy', 'status.state']);
  });

  it('handles bigint values as leaves', () => {
    expect(buildUpdateMaskPaths({ spec: { restartTrigger: 1n } })).toEqual([
      'spec.restart_trigger',
    ]);
  });

  it('treats objects with $typeName as leaf values (protobuf messages)', () => {
    const timestamp = { $typeName: 'google.protobuf.Timestamp', seconds: 123n, nanos: 0 };
    expect(buildUpdateMaskPaths({ spec: { restartRequestedAt: timestamp } })).toEqual([
      'spec.restart_requested_at',
    ]);
  });

  it('handles already snake_case keys without modification', () => {
    expect(buildUpdateMaskPaths({ spec: { run_strategy: 'Always' } })).toEqual([
      'spec.run_strategy',
    ]);
  });

  it('uses the protobuf schema to treat map fields as leaves', () => {
    expect(
      buildUpdateMaskPaths(
        { spec: { hardware: { capabilities: { 'sr-iov': 'true' } } } },
        { schema: BareMetalInstanceTypeSchema },
      ),
    ).toEqual(['spec.hardware.capabilities']);
  });

  it('returns an empty array for an empty object', () => {
    expect(buildUpdateMaskPaths({})).toEqual([]);
  });

  it('handles protobuf oneof fields using the case as the field name', () => {
    const body = {
      spec: {
        title: 'My IDP',
        config: {
          case: 'oidc',
          value: {
            authorizationUrl: 'https://example.com/auth',
            clientId: 'my-client',
          },
        },
      },
    };
    expect(buildUpdateMaskPaths(body)).toEqual([
      'spec.title',
      'spec.oidc.authorization_url',
      'spec.oidc.client_id',
    ]);
  });

  it('handles oneof with a non-object value as a leaf', () => {
    const body = {
      config: { case: 'simpleValue', value: 'hello' },
    };
    expect(buildUpdateMaskPaths(body)).toEqual(['simple_value']);
  });
});
