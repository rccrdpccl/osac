import {
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
  Stack,
  StackItem,
  Title,
} from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import { useTranslation } from '../../../../hooks/useTranslation';
import type {
  BareMetalAcceleratorValue,
  BareMetalDiskValue,
  BareMetalInstanceTypeFormValues,
  BareMetalNetworkPortValue,
} from '../values';

const EMPTY_VALUE = '—';

const formatValue = (value: string | number | bigint | undefined): string =>
  value === undefined || value === '' ? EMPTY_VALUE : value.toString();

const formatAccelerators = (accelerators: BareMetalAcceleratorValue[]): string =>
  accelerators.length === 0
    ? EMPTY_VALUE
    : accelerators
        .map((accelerator) =>
          [
            accelerator.type,
            accelerator.model,
            accelerator.vendor,
            formatValue(accelerator.memoryGb),
          ]
            .filter(Boolean)
            .join(' · '),
        )
        .join(', ');

const formatDisks = (disks: BareMetalDiskValue[]): string =>
  disks.length === 0
    ? EMPTY_VALUE
    : disks
        .map((disk) => `${disk.type} · ${formatValue(disk.capacityGb)} GB · ${disk.interface}`)
        .join(', ');

const formatNetworkPorts = (networkPorts: BareMetalNetworkPortValue[]): string =>
  networkPorts.length === 0
    ? EMPTY_VALUE
    : networkPorts
        .map((port) => [port.name, port.role, port.type, port.speed].filter(Boolean).join(' · '))
        .join(', ');

const formatPairs = (pairs: { key: string; value: string }[]): string =>
  pairs.length === 0
    ? EMPTY_VALUE
    : pairs.map(({ key, value }) => (value ? `${key}=${value}` : key)).join(', ');

const ReviewStep = () => {
  const { t } = useTranslation();
  const { values } = useFormikContext<BareMetalInstanceTypeFormValues>();

  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Review')}
        </Title>
      </StackItem>
      <StackItem>
        <DescriptionList isHorizontal isCompact aria-label={t('General')}>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Name')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatValue(values.metadata.name)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Description')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatValue(values.spec.description)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Host labels')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatPairs(values.spec.hostLabelSelector)}
            </DescriptionListDescription>
          </DescriptionListGroup>
        </DescriptionList>
      </StackItem>
      <StackItem>
        <Title headingLevel="h3" size="md">
          {t('CPU & Memory')}
        </Title>
      </StackItem>
      <StackItem>
        <DescriptionList isHorizontal isCompact aria-label={t('CPU & Memory')}>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Cores')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatValue(values.spec.cpu.cores)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Architecture')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatValue(values.spec.cpu.architecture)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Model')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatValue(values.spec.cpu.model)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Threads per core')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatValue(values.spec.cpu.threadsPerCore)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Memory')}</DescriptionListTerm>
            <DescriptionListDescription>
              {`${formatValue(values.spec.memory.totalGb)} GB · ${formatValue(values.spec.memory.type)}`}
            </DescriptionListDescription>
          </DescriptionListGroup>
        </DescriptionList>
      </StackItem>
      <StackItem>
        <Title headingLevel="h3" size="md">
          {t('Hardware')}
        </Title>
      </StackItem>
      <StackItem>
        <DescriptionList isHorizontal isCompact aria-label={t('Hardware')}>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Accelerators')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatAccelerators(values.spec.accelerators)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Disks')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatDisks(values.spec.disks)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Network ports')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatNetworkPorts(values.spec.networkPorts)}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Capabilities')}</DescriptionListTerm>
            <DescriptionListDescription>
              {formatPairs(values.spec.capabilities)}
            </DescriptionListDescription>
          </DescriptionListGroup>
        </DescriptionList>
      </StackItem>
    </Stack>
  );
};

export default ReviewStep;
