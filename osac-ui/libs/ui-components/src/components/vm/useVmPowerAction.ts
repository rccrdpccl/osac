import { getPowerActionErrorTitle, getPowerActionSuccessTitle } from './powerActionErrorTitle';
import {
  type ComputeInstancePowerAction,
  usePatchComputeInstance,
} from '../../api/v1/compute-instance';
import { useTranslation } from '../../hooks/useTranslation';
import { getErrorMessage } from '../../utils/error';
import { useToast } from '../Toast/useToast';

/** Runs a VM lifecycle power action and surfaces a toast on success or failure. */
export const useVmPowerAction = () => {
  const { t } = useTranslation();
  const { addToast } = useToast();
  const patchVm = usePatchComputeInstance();

  const runPowerAction = (
    vmId: string,
    vmName: string,
    powerAction: ComputeInstancePowerAction,
  ) => {
    patchVm.mutate(
      { id: vmId, powerAction },
      {
        onSuccess: () => {
          addToast({
            variant: 'success',
            title: getPowerActionSuccessTitle(t, powerAction, vmName),
          });
        },
        onError: (error) => {
          addToast({
            variant: 'danger',
            title: getPowerActionErrorTitle(t, powerAction, vmName),
            description: getErrorMessage(error),
          });
        },
      },
    );
  };

  return { runPowerAction };
};
