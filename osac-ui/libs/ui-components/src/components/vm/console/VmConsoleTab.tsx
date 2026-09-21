import { useState } from 'react';
import { Bullseye, EmptyState, EmptyStateBody, Stack, StackItem } from '@patternfly/react-core';

import type { ComputeInstance } from '@osac/types';
import { ComputeInstanceState } from '@osac/types';

import VmConsoleView from './VmConsoleView';
import { useTranslation } from '../../../hooks/useTranslation';
import {
  CONSOLE_FULLSCREEN_CONTAINER_CLASS_NAME,
  CONSOLE_STACK_CLASS_NAME,
} from '../../Console/console-viewport';
import type { ConsoleTransport } from '../../Console/console.types';
import { useConsoleFullscreen } from '../../Console/useConsoleFullscreen';

import './VmConsoleTab.css';

interface Props {
  vm: ComputeInstance;
}

const VmConsoleTab = ({ vm }: Props) => {
  const { t } = useTranslation();
  const { containerRef, isFullscreen, toggleFullscreen } = useConsoleFullscreen();
  const isVmRunning = vm.status?.state === ComputeInstanceState.RUNNING;
  // Default to VNC; the choice is intentionally not persisted across visits.
  const [transport, setTransport] = useState<ConsoleTransport>('vnc');

  if (!isVmRunning) {
    return (
      <Bullseye className={CONSOLE_STACK_CLASS_NAME}>
        <EmptyState headingLevel="h2" titleText={t('Console unavailable')}>
          <EmptyStateBody>
            {t('The console is available when the virtual machine is running.')}
          </EmptyStateBody>
        </EmptyState>
      </Bullseye>
    );
  }

  return (
    <Stack hasGutter>
      <StackItem>
        {/* Plain div: Fullscreen API needs a real DOM node; PF Stack is not forwardRef. */}
        <div ref={containerRef} className={CONSOLE_FULLSCREEN_CONTAINER_CLASS_NAME}>
          {/* Keyed by transport so switching remounts VmConsoleView, reusing
              useConsoleSession's unmount cleanup to tear down the old session before the
              new one connects. The container div stays mounted, preserving fullscreen. */}
          <VmConsoleView
            key={transport}
            resourceId={vm.id}
            transport={transport}
            onTransportChange={setTransport}
            isFullscreen={isFullscreen}
            onToggleFullscreen={() => void toggleFullscreen()}
          />
        </div>
      </StackItem>
    </Stack>
  );
};

export default VmConsoleTab;
