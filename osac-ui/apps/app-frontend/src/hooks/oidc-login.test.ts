import { describe, expect, it } from 'vitest';

import { roleFromRoles } from './oidc-login';

describe('roleFromRoles', () => {
  it('returns admin when groups include admins', () => {
    expect(roleFromRoles(['tenant-admin'], ['admins'])).toBe('admin');
  });

  it('returns admin when groups include admins even with tenant-idp-manager role', () => {
    expect(roleFromRoles(['tenant-idp-manager'], ['admins'])).toBe('admin');
  });

  it('returns admin when roles include cloud-provider-admin', () => {
    expect(roleFromRoles(['cloud-provider-admin'], [])).toBe('admin');
  });

  it('returns admin when roles include cloud-provider-admin even with tenant-admin role', () => {
    expect(roleFromRoles(['cloud-provider-admin', 'tenant-admin'], [])).toBe('admin');
  });

  it('returns tenant-admin when roles include tenant-admin and not in admins group', () => {
    expect(roleFromRoles(['tenant-admin'], [])).toBe('tenant-admin');
  });

  it('returns tenant-admin over tenant-idp-manager when both roles present', () => {
    expect(roleFromRoles(['tenant-admin', 'tenant-idp-manager'], [])).toBe('tenant-admin');
  });

  it('returns tenant-idp-manager when roles include tenant-idp-manager and not tenant-admin', () => {
    expect(roleFromRoles(['tenant-idp-manager'], [])).toBe('tenant-idp-manager');
  });

  it('returns tenant-user when no recognized group or role is present', () => {
    expect(roleFromRoles([], [])).toBe('tenant-user');
  });

  it('returns tenant-user for unrecognized roles and groups', () => {
    expect(roleFromRoles(['some-other-role'], ['some-group'])).toBe('tenant-user');
  });
});
