import { describe, expect, it } from 'vitest';

import { defaultRouteForRole } from './shellRoutes';

describe('defaultRouteForRole', () => {
  it('lands *role* on default page', () => {
    expect(defaultRouteForRole('tenant-user')).toBe('/catalog');
    expect(defaultRouteForRole('tenant-admin')).toBe('/catalog');
    expect(defaultRouteForRole('tenant-idp-manager')).toBe('/tenant/identity-provider');
    expect(defaultRouteForRole('admin')).toBe('/admin/tenants');
  });
});
