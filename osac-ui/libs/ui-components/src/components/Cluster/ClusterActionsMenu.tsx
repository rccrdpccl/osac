import { useState } from 'react';
import { Dropdown, DropdownItem, DropdownList, MenuToggle } from '@patternfly/react-core';
import { EllipsisVIcon } from '@patternfly/react-icons/dist/esm/icons/ellipsis-v-icon';

import { type Cluster, ClusterState } from '@osac/types';

import ClusterDeleteConfirmModal from './ClusterDeleteConfirmModal';
import { useTranslation } from '../../hooks/useTranslation';

interface ClusterActionsMenuProps {
  cluster: Cluster;
}

const ClusterActionsMenu = ({ cluster }: ClusterActionsMenuProps) => {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [deleteOpen, setDeleteOpen] = useState(false);

  const canDelete = cluster.status?.state !== ClusterState.DELETING;

  return (
    <>
      {deleteOpen && (
        <ClusterDeleteConfirmModal
          cluster={cluster}
          onClose={() => setDeleteOpen(false)}
          onSuccess={() => setDeleteOpen(false)}
        />
      )}
      <Dropdown
        isOpen={open}
        onOpenChange={setOpen}
        toggle={(ref) => (
          <MenuToggle
            ref={ref}
            variant="plain"
            onClick={() => setOpen((o) => !o)}
            aria-label={t('Actions for {{name}}', { name: cluster.metadata?.name ?? cluster.id })}
          >
            <EllipsisVIcon />
          </MenuToggle>
        )}
        popperProps={{ position: 'right' }}
      >
        <DropdownList>
          <DropdownItem
            value="delete"
            isDisabled={!canDelete}
            onClick={() => {
              if (!canDelete) {
                return;
              }
              setDeleteOpen(true);
              setOpen(false);
            }}
          >
            {t('Delete')}
          </DropdownItem>
        </DropdownList>
      </Dropdown>
    </>
  );
};

export default ClusterActionsMenu;
