import { RedhatIcon } from '@patternfly/react-icons/dist/esm/icons/redhat-icon';
import { WindowsIcon } from '@patternfly/react-icons/dist/esm/icons/windows-icon';

export type OsType = 'rhel' | 'windows' | 'linux';

import './GuestOsIcon.css';
import linuxMascotUrl from '../../assets/guest-os-tux-linux.png';

type GuestOsIconSize = 'sm' | 'md' | 'lg';

const SIZE_CLASS: Record<GuestOsIconSize, string> = {
  sm: 'osac-guest-os-icon--sm',
  md: 'osac-guest-os-icon--md',
  lg: 'osac-guest-os-icon--lg',
};

interface GuestOsIconProps {
  os?: OsType;
  size?: GuestOsIconSize;
  className?: string;
}

export const GuestOsIcon = ({ os, size = 'md', className }: GuestOsIconProps) => {
  const sizeClass = SIZE_CLASS[size];
  const rootClass = ['osac-guest-os-icon', sizeClass, className].filter(Boolean).join(' ');

  if (os === 'windows') {
    return <WindowsIcon className={`${rootClass} osac-guest-os-icon--windows`} aria-hidden />;
  }
  if (os === 'rhel') {
    return <RedhatIcon className={`${rootClass} osac-guest-os-icon--rhel`} aria-hidden />;
  }

  return (
    <img
      src={linuxMascotUrl}
      alt=""
      className={`${rootClass} osac-guest-os-icon--linux`}
      width={size === 'sm' ? 16 : size === 'lg' ? 28 : 24}
      height={size === 'sm' ? 16 : size === 'lg' ? 28 : 24}
    />
  );
};
