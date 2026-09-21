import { useNavigate, useParams } from 'react-router-dom';
import { Alert, Bullseye, Spinner } from '@patternfly/react-core';

import { useVirtualNetwork } from '../../api/v1/networking';
import { AttachNatGatewayWizard } from '../../components/networking/AttachNatGatewayWizard';
import { useTranslation } from '../../hooks/useTranslation';
import { getErrorMessage } from '../../utils/error';

const AttachNatGatewayWizardPage = () => {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { id = '' } = useParams<{ id: string }>();
  const { data: virtualNetwork, isLoading, error } = useVirtualNetwork(id);

  if (isLoading) {
    return (
      <Bullseye>
        <Spinner />
      </Bullseye>
    );
  }

  if (error || !virtualNetwork) {
    return (
      <Alert variant="danger" isInline title={t('Failed to load virtual network')}>
        {error ? getErrorMessage(error) : t('Virtual network not found.')}
      </Alert>
    );
  }

  return (
    <AttachNatGatewayWizard
      virtualNetwork={virtualNetwork}
      onClose={() => navigate(`/networking/virtual-networks/${id}`)}
    />
  );
};

export default AttachNatGatewayWizardPage;
