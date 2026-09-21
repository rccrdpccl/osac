import { Architecture, GuestOSFamily } from '@osac/types';

export interface DiskImageFormValues {
  metadata: { name: string; tenant: string };
  spec: {
    sourceRef: string;
    guestOsFamily: GuestOSFamily;
    architecture: Architecture[];
  };
}

export const diskImageCreateValues: DiskImageFormValues = {
  metadata: { name: '', tenant: '' },
  spec: {
    sourceRef: '',
    guestOsFamily: GuestOSFamily.GUEST_OS_FAMILY_LINUX,
    architecture: [],
  },
};
