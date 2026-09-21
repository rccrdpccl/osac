import { Table, Tbody, Td, Th, Thead, Tr } from '@patternfly/react-table';

import type { ExternalIPPool } from '@osac/types/private';
import ResourceNameField from '@osac/ui-components/components/Resource/ResourceNameField.tsx';

import ExternalIpPoolActionsMenu from './ExternalIpPoolActionsMenu';
import ExternalIpPoolStatusLabel from './ExternalIpPoolStatusLabel';
import { useTranslation } from '../../hooks/useTranslation';

interface ExternalIpPoolsTableProps {
  pools: ExternalIPPool[];
}

const formatCount = (value?: bigint): string => (value === undefined ? '—' : `${value}`);

export const ExternalIpPoolsTable = ({ pools }: ExternalIpPoolsTableProps) => {
  const { t } = useTranslation();

  // Show the single CIDR inline; collapse multiple into a "<n> CIDRs" summary.
  const formatCidrs = (cidrs?: string[]): string => {
    if (!cidrs || cidrs.length === 0) {
      return '—';
    }
    if (cidrs.length === 1) {
      return cidrs[0];
    }
    return t('{{count}} CIDRs', { count: cidrs.length });
  };

  return (
    <Table aria-label={t('External IP pools')} variant="compact">
      <Thead>
        <Tr>
          <Th>{t('Name')}</Th>
          <Th>{t('Status')}</Th>
          <Th>{t('CIDRs')}</Th>
          <Th>{t('Available')}</Th>
          <Th>{t('Total')}</Th>
          <Th aria-label={t('Actions')} />
        </Tr>
      </Thead>
      <Tbody>
        {pools.map((pool) => (
          <Tr key={pool.id}>
            <Td dataLabel={t('Name')}>
              <ResourceNameField
                resource={pool}
                detailsUrl={`/admin/infrastructure/external-ip-pools/${encodeURIComponent(pool.id)}`}
              />
            </Td>
            <Td dataLabel={t('Status')}>
              <ExternalIpPoolStatusLabel state={pool.status?.state} />
            </Td>
            <Td dataLabel={t('CIDRs')}>{formatCidrs(pool.spec?.cidrs)}</Td>
            <Td dataLabel={t('Available')}>{formatCount(pool.status?.available)}</Td>
            <Td dataLabel={t('Total')}>{formatCount(pool.status?.total)}</Td>
            <Td dataLabel={t('Actions')} isActionCell>
              <ExternalIpPoolActionsMenu pool={pool} />
            </Td>
          </Tr>
        ))}
      </Tbody>
    </Table>
  );
};
