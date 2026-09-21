import { useNavigate, useParams } from 'react-router-dom';
import {
  Alert,
  Breadcrumb,
  BreadcrumbItem,
  Bullseye,
  Button,
  PageSection,
  Spinner,
  Stack,
  Title,
} from '@patternfly/react-core';

import { BareMetalInstanceTypes } from '@osac/types/private';
import { useGetResource } from '@osac/ui-components/api/use-resource';

import BareMetalInstanceTypeWizard from './BareMetalInstanceTypeWizard';
import { useTranslation } from '../../../hooks/useTranslation';
import { getErrorMessage } from '../../../utils/error';
import { BAREMETAL_INSTANCE_TYPES_LIST_ROUTE } from '../AdminBareMetalInstanceTypeListPage';

const AdminBareMetalInstanceTypeCreatePage = () => {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const { id } = useParams<{ id: string }>();
  const isEdit = Boolean(id);

  const { data, isLoading, error } = useGetResource(
    BareMetalInstanceTypes,
    { id },
    { enabled: !!id },
  );

  const title = isEdit ? t('Edit bare metal instance type') : t('Create bare metal instance type');

  return (
    <>
      <PageSection hasBodyWrapper={false}>
        <Stack hasGutter>
          <Breadcrumb>
            <BreadcrumbItem>
              <Button
                variant="link"
                isInline
                onClick={() => navigate(BAREMETAL_INSTANCE_TYPES_LIST_ROUTE)}
              >
                {t('Bare metal instance types')}
              </Button>
            </BreadcrumbItem>
            {isEdit && (
              <BreadcrumbItem>
                <Button
                  variant="link"
                  isInline
                  onClick={() => navigate(`${BAREMETAL_INSTANCE_TYPES_LIST_ROUTE}/${id}`)}
                >
                  {data?.object?.metadata?.name || id}
                </Button>
              </BreadcrumbItem>
            )}
            <BreadcrumbItem isActive>{isEdit ? t('Edit') : t('Create')}</BreadcrumbItem>
          </Breadcrumb>
          <Title headingLevel="h1" size="3xl">
            {title}
          </Title>
        </Stack>
      </PageSection>
      {isEdit && isLoading ? (
        <PageSection hasBodyWrapper={false}>
          <Bullseye>
            <Spinner />
          </Bullseye>
        </PageSection>
      ) : isEdit && error ? (
        <PageSection hasBodyWrapper={false}>
          <Alert variant="danger" isInline title={t('Failed to fetch bare metal instance type')}>
            {getErrorMessage(error)}
          </Alert>
        </PageSection>
      ) : (
        <BareMetalInstanceTypeWizard bareMetalInstanceType={data?.object} />
      )}
    </>
  );
};

export default AdminBareMetalInstanceTypeCreatePage;
