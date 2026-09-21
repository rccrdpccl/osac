import { type BareMetalInstanceType as PrivateBareMetalInstanceType } from '@osac/types/private';

import type { KeyValuePair } from '../../Form/KeyValueMapField';

export interface BareMetalDiskValue {
  type: string;
  capacityGb: bigint | undefined;
  interface: string;
}

export interface BareMetalAcceleratorValue {
  type: string;
  model: string;
  vendor: string;
  memoryGb: number | undefined;
}

export interface BareMetalNetworkPortValue {
  name: string;
  role: string;
  type: string;
  speed: string;
}

export interface BareMetalInstanceTypeFormValues {
  metadata: { name: string };
  spec: {
    description: string;
    cpu: {
      cores: number | undefined;
      architecture: string;
      model: string;
      threadsPerCore: number | undefined;
    };
    memory: { totalGb: bigint | undefined; type: string };
    disks: BareMetalDiskValue[];
    accelerators: BareMetalAcceleratorValue[];
    networkPorts: BareMetalNetworkPortValue[];
    capabilities: KeyValuePair[];
    hostLabelSelector: KeyValuePair[];
  };
}

export const emptyDiskValue = (): BareMetalDiskValue => ({
  type: '',
  capacityGb: undefined,
  interface: '',
});

export const emptyAcceleratorValue = (): BareMetalAcceleratorValue => ({
  type: '',
  model: '',
  vendor: '',
  memoryGb: undefined,
});

export const emptyNetworkPortValue = (): BareMetalNetworkPortValue => ({
  name: '',
  role: '',
  type: '',
  speed: '',
});

const recordToPairs = (record: { [key: string]: string } | undefined): KeyValuePair[] =>
  Object.entries(record ?? {}).map(([key, value]) => ({ key, value }));

export const getBareMetalInstanceTypeValues = (
  existing?: PrivateBareMetalInstanceType,
): BareMetalInstanceTypeFormValues => {
  const spec = existing?.spec;
  const hardware = spec?.hardware;

  return {
    metadata: { name: existing?.metadata?.name ?? '' },
    spec: {
      description: spec?.description ?? '',
      cpu: {
        cores: hardware?.cpu?.cores,
        architecture: hardware?.cpu?.architecture ?? '',
        model: hardware?.cpu?.model ?? '',
        threadsPerCore: hardware?.cpu?.threadsPerCore,
      },
      memory: {
        totalGb: hardware?.memory?.totalGb,
        type: hardware?.memory?.type ?? '',
      },
      disks: (hardware?.disks ?? []).map((disk) => ({
        type: disk.type,
        capacityGb: disk.capacityGb,
        interface: disk.interface,
      })),
      accelerators: (hardware?.accelerators ?? []).map((accelerator) => ({
        type: accelerator.type,
        model: accelerator.model,
        vendor: accelerator.vendor ?? '',
        memoryGb: accelerator.memoryGb,
      })),
      networkPorts: (hardware?.networkPorts ?? []).map((port) => ({
        name: port.name,
        role: port.role,
        type: port.type,
        speed: port.speed,
      })),
      capabilities: recordToPairs(hardware?.capabilities),
      hostLabelSelector: existing
        ? recordToPairs(spec?.hostLabelSelector?.matchLabels)
        : [{ key: '', value: '' }],
    },
  };
};
