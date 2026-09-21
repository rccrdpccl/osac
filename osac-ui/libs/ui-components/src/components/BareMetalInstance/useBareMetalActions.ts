import type { TFunction } from 'i18next';

import type { BareMetalInstance } from '@osac/types';
import { BareMetalInstanceState } from '@osac/types';

import {
  type BareMetalPowerAction,
  type PatchBareMetalInstanceInput,
  usePatchBareMetalInstance,
} from '../../api/v1/baremetal-instance';
import { useTranslation } from '../../hooks/useTranslation';
import { getErrorMessage } from '../../utils/error';
import { useToast } from '../Toast/useToast';

const getBmActionSuccessTitle = (t: TFunction, action: BareMetalPowerAction, name: string) => {
  switch (action) {
    case 'start':
      return t('Start initiated for {{name}}', { name });
    case 'stop':
      return t('Stop initiated for {{name}}', { name });
    case 'restart':
      return t('Restart initiated for {{name}}', { name });
  }
};

const getBmActionErrorTitle = (t: TFunction, action: BareMetalPowerAction, name: string) => {
  switch (action) {
    case 'start':
      return t('Failed to start bare metal instance {{name}}', { name });
    case 'stop':
      return t('Failed to stop bare metal instance {{name}}', { name });
    case 'restart':
      return t('Failed to restart bare metal instance {{name}}', { name });
  }
};

export const useBareMetalActions = (instance: BareMetalInstance) => {
  const { t } = useTranslation();
  const { addToast } = useToast();
  const patch = usePatchBareMetalInstance();

  const name = instance.metadata?.name ?? instance.id;
  const state = instance.status?.state;
  const canStart = state === BareMetalInstanceState.STOPPED;
  const canStop = state === BareMetalInstanceState.RUNNING;
  const canRestart = state === BareMetalInstanceState.RUNNING;
  const canDelete = state !== BareMetalInstanceState.DELETING;

  const mutateWithToast = (input: PatchBareMetalInstanceInput) => {
    patch.mutate(input, {
      onSuccess: () => {
        addToast({
          variant: 'success',
          title: getBmActionSuccessTitle(t, input.action, name),
        });
      },
      onError: (error) => {
        addToast({
          variant: 'danger',
          title: getBmActionErrorTitle(t, input.action, name),
          description: getErrorMessage(error),
        });
      },
    });
  };

  const start = () => {
    if (canStart) {
      mutateWithToast({ id: instance.id, action: 'start' });
    }
  };

  const stop = () => {
    if (canStop) {
      mutateWithToast({ id: instance.id, action: 'stop' });
    }
  };

  const restart = () => {
    if (canRestart) {
      mutateWithToast({
        id: instance.id,
        action: 'restart',
        currentTrigger: instance.spec?.restartTrigger ?? 0n,
      });
    }
  };

  return { canStart, canStop, canRestart, canDelete, start, stop, restart };
};
