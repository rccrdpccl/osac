import { BareMetalInstanceState } from '@osac/types';

import { useTranslation } from '../../hooks/useTranslation';
import { ResourceStatusLabel } from '../Resource/ResourceStatusLabel';

interface BareMetalStatusLabelProps {
  state?: BareMetalInstanceState;
}

export const BareMetalStatusLabel = ({ state }: BareMetalStatusLabelProps) => {
  const { t } = useTranslation();

  switch (state) {
    case BareMetalInstanceState.RUNNING:
      return <ResourceStatusLabel status="ready" text={t('Running')} />;
    case BareMetalInstanceState.STOPPED:
      return <ResourceStatusLabel status="unspecified" text={t('Stopped')} />;
    case BareMetalInstanceState.PROVISIONING:
      return <ResourceStatusLabel status="progressing" text={t('Provisioning')} />;
    case BareMetalInstanceState.STARTING:
      return <ResourceStatusLabel status="progressing" text={t('Starting')} />;
    case BareMetalInstanceState.STOPPING:
      return <ResourceStatusLabel status="progressing" text={t('Stopping')} />;
    case BareMetalInstanceState.DELETING:
      return <ResourceStatusLabel status="progressing" text={t('Deleting')} />;
    case BareMetalInstanceState.FAILED:
      return <ResourceStatusLabel status="failed" text={t('Failed')} />;
    default:
      return <ResourceStatusLabel status="unspecified" text={t('Unknown')} />;
  }
};
