import { describe, expect, it, vi } from 'vitest';

import type { ComputeInstanceCatalogItem } from '@osac/types';
import { tIdentity } from '@osac/ui-components/test-utils/i18n';

import { applyVmCatalogGeneralDefaults } from './applyCatalogGeneralDefaults';
import { buildComputeInstanceCreatePayload, createEmptyComputeInstanceValues } from './payload';

describe('applyVmCatalogGeneralDefaults', () => {
  it('prefills ssh default from catalog when defined', () => {
    const setFieldValue = vi.fn();
    const helpers = { setFieldValue } as never;

    applyVmCatalogGeneralDefaults(
      {
        id: 'cat-locked',
        fieldDefinitions: [
          {
            path: 'ssh_public_key',
            editable: false,
            default: { string_value: 'ssh-ed25519 locked' },
          },
        ],
      } as unknown as ComputeInstanceCatalogItem,
      helpers,
      tIdentity,
    );
    expect(setFieldValue).toHaveBeenCalledWith('spec.sshPublicKey', 'ssh-ed25519 locked');

    setFieldValue.mockClear();
    applyVmCatalogGeneralDefaults(
      {
        id: 'cat-editable',
        fieldDefinitions: [
          {
            path: 'ssh_public_key',
            editable: true,
            default: { string_value: 'ssh-ed25519 default' },
          },
        ],
      } as unknown as ComputeInstanceCatalogItem,
      helpers,
      tIdentity,
    );
    expect(setFieldValue).toHaveBeenCalledWith('spec.sshPublicKey', 'ssh-ed25519 default');
  });
});

describe('buildComputeInstanceCreatePayload ssh key', () => {
  it('includes read-only ssh key value in client payload', () => {
    const values = {
      ...createEmptyComputeInstanceValues(),
      catalogItemId: 'cat-locked',
      metadata: { name: 'web-01', project: '' },
      spec: {
        ...createEmptyComputeInstanceValues().spec,
        sshPublicKey: 'ssh-ed25519 locked',
        networking: {
          virtualNetwork: 'vn-1',
          subnet: 'subnet-1',
          securityGroups: ['sg-1'],
        },
      },
    };

    const vm = buildComputeInstanceCreatePayload(values, {
      id: 'cat-locked',
    } as ComputeInstanceCatalogItem);
    expect(vm.spec?.sshPublicKey).toBe('ssh-ed25519 locked');
  });

  it('includes prefilled catalog ssh default in client payload', () => {
    const values = {
      ...createEmptyComputeInstanceValues(),
      catalogItemId: 'cat-editable',
      metadata: { name: 'web-02', project: '' },
      spec: {
        ...createEmptyComputeInstanceValues().spec,
        sshPublicKey: 'ssh-ed25519 default',
        networking: {
          virtualNetwork: 'vn-1',
          subnet: 'subnet-1',
          securityGroups: ['sg-1'],
        },
      },
    };

    const vm = buildComputeInstanceCreatePayload(values, {
      id: 'cat-editable',
    } as ComputeInstanceCatalogItem);
    expect(vm.spec?.sshPublicKey).toBe('ssh-ed25519 default');
  });

  it('omits ssh key when tenant clears prefilled default', () => {
    const values = {
      ...createEmptyComputeInstanceValues(),
      catalogItemId: 'cat-editable',
      metadata: { name: 'web-02', project: '' },
      spec: {
        ...createEmptyComputeInstanceValues().spec,
        networking: {
          virtualNetwork: 'vn-1',
          subnet: 'subnet-1',
          securityGroups: ['sg-1'],
        },
      },
    };

    const vm = buildComputeInstanceCreatePayload(values, {
      id: 'cat-editable',
    } as ComputeInstanceCatalogItem);
    expect(vm.spec?.sshPublicKey).toBeUndefined();
  });
});
