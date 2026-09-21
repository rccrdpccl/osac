import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Button, Flex } from '@patternfly/react-core';
import DumpsterIcon from '@patternfly/react-icons/dist/esm/icons/dumpster-icon';

import type { Project } from '@osac/types';

import { useTranslation } from '../../../hooks/useTranslation';
import ProjectDeleteModal from '../ProjectDeleteModal';

interface ProjectDetailsActionButtonsProps {
  project: Project;
}

const ProjectDetailsActionButtons = ({ project }: ProjectDetailsActionButtonsProps) => {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [deleteOpen, setDeleteOpen] = useState(false);

  return (
    <>
      {deleteOpen && (
        <ProjectDeleteModal
          project={project}
          onClose={() => setDeleteOpen(false)}
          onSuccess={() => navigate('/projects', { replace: true })}
        />
      )}
      <Flex
        justifyContent={{ default: 'justifyContentFlexEnd' }}
        spaceItems={{ default: 'spaceItemsSm' }}
        flexWrap={{ default: 'wrap' }}
      >
        <Button variant="danger" icon={<DumpsterIcon />} onClick={() => setDeleteOpen(true)}>
          {t('Delete')}
        </Button>
      </Flex>
    </>
  );
};

export default ProjectDetailsActionButtons;
