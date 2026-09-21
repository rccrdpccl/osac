export interface InstanceTypeCreateFormValues {
  metadata: { name: string };
  spec: {
    description: string;
    cores: string;
    memoryGib: string;
    gpu: { pciDeviceSelector: string; resourceName: string; count: string };
  };
}

export const instanceTypeCreateValues: InstanceTypeCreateFormValues = {
  metadata: { name: '' },
  spec: {
    description: '',
    cores: '',
    memoryGib: '',
    gpu: { pciDeviceSelector: '', resourceName: '', count: '' },
  },
};
