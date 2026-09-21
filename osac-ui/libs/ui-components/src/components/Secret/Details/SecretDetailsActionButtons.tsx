import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Button, Flex } from '@patternfly/react-core';
import DumpsterIcon from '@patternfly/react-icons/dist/esm/icons/dumpster-icon';
import PencilAltIcon from '@patternfly/react-icons/dist/esm/icons/pencil-alt-icon';

import { Secret } from '@osac/types';

import { useTranslation } from '../../../hooks/useTranslation';
import SecretDeleteModal from '../SecretDeleteModal';

interface SecretDetailsActionButtonsProps {
  secret: Secret;
}

const SecretDetailsActionButtons = ({ secret }: SecretDetailsActionButtonsProps) => {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [deleteOpen, setDeleteOpen] = useState(false);

  return (
    <>
      {deleteOpen && (
        <SecretDeleteModal
          secret={secret}
          onClose={() => setDeleteOpen(false)}
          onSuccess={() => navigate('/secrets', { replace: true })}
        />
      )}
      <Flex
        justifyContent={{ default: 'justifyContentFlexEnd' }}
        spaceItems={{ default: 'spaceItemsSm' }}
        flexWrap={{ default: 'wrap' }}
      >
        <Button
          variant="secondary"
          icon={<PencilAltIcon />}
          onClick={() => navigate(`/secrets/${secret.id}/edit`)}
        >
          {t('Edit')}
        </Button>
        <Button variant="danger" icon={<DumpsterIcon />} onClick={() => setDeleteOpen(true)}>
          {t('Delete')}
        </Button>
      </Flex>
    </>
  );
};

export default SecretDetailsActionButtons;
