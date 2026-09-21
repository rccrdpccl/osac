import type { TFunction } from 'i18next';

export const VM_DETAIL_OVERVIEW_TAB_ID = 'vm-detail-overview';
export const VM_DETAIL_NETWORKING_TAB_ID = 'vm-detail-networking';
export const VM_DETAIL_CONSOLE_TAB_ID = 'vm-detail-console';

export const getVmDetailTabLabels = (t: TFunction): string[] => [
  t('Overview'),
  t('Networking'),
  t('Console'),
];
