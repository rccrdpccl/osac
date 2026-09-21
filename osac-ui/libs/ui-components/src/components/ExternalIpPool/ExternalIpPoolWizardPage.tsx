import { useNavigate } from 'react-router-dom';
import {
  Breadcrumb,
  BreadcrumbItem,
  Button,
  PageSection,
  Stack,
  Title,
} from '@patternfly/react-core';

import { useTranslation } from '@osac/ui-components/hooks/useTranslation';

import ExternalIpPoolWizard from './ExternalIpPoolWizard';
import { EXTERNAL_IP_POOLS_LIST_PATH } from './values';

export const ExternalIpPoolWizardPage = () => {
  const { t } = useTranslation();
  const navigate = useNavigate();

  return (
    <>
      <PageSection hasBodyWrapper={false}>
        <Stack hasGutter>
          <Breadcrumb>
            <BreadcrumbItem>
              <Button variant="link" isInline onClick={() => navigate(EXTERNAL_IP_POOLS_LIST_PATH)}>
                {t('External IP pools')}
              </Button>
            </BreadcrumbItem>
            <BreadcrumbItem isActive>{t('Create')}</BreadcrumbItem>
          </Breadcrumb>
          <Title headingLevel="h1" size="3xl">
            {t('Create external IP pool')}
          </Title>
        </Stack>
      </PageSection>
      <ExternalIpPoolWizard />
    </>
  );
};
