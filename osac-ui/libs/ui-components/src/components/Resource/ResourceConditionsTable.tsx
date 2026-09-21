import { Content } from '@patternfly/react-core';
import { Table, Tbody, Td, Th, Thead, Tr } from '@patternfly/react-table';

import type {
  BareMetalInstanceCondition,
  ClusterCondition,
  ComputeInstanceCondition,
} from '@osac/types';

import {
  type ConditionResourceKind,
  displayValue,
  formatConditionStatusForDisplay,
  humanizeConditionType,
} from '../../utils/detailFormatters';
import { Timestamp } from '../Primitives/Timestamp';

interface ResourceConditionsTableProps {
  conditions: (ClusterCondition | ComputeInstanceCondition | BareMetalInstanceCondition)[];
  ariaLabel: string;
  conditionResourceKind: ConditionResourceKind;
  emptyMessage?: string;
}

export const ResourceConditionsTable = ({
  conditions,
  ariaLabel,
  conditionResourceKind,
  emptyMessage = 'No conditions reported.',
}: ResourceConditionsTableProps) => {
  if (conditions.length === 0) {
    return <Content component="p">{emptyMessage}</Content>;
  }

  return (
    <Table aria-label={ariaLabel} variant="compact">
      <Thead>
        <Tr>
          <Th>Type</Th>
          <Th>Status</Th>
          <Th>Reason</Th>
          <Th>Message</Th>
          <Th>Last transition</Th>
        </Tr>
      </Thead>
      <Tbody>
        {conditions.map((c) => (
          <Tr key={c.type}>
            <Td dataLabel="Type">{humanizeConditionType(c.type, conditionResourceKind)}</Td>
            <Td dataLabel="Status">{formatConditionStatusForDisplay(c.status)}</Td>
            <Td dataLabel="Reason">{displayValue(c.reason)}</Td>
            <Td dataLabel="Message">{displayValue(c.message)}</Td>
            <Td dataLabel="Last transition">
              <Timestamp value={c.lastTransitionTime} />
            </Td>
          </Tr>
        ))}
      </Tbody>
    </Table>
  );
};
