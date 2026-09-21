import { useNavigate } from 'react-router-dom';
import { Breadcrumb, BreadcrumbItem, Button } from '@patternfly/react-core';

import DiskImageForm, { DISK_IMAGES_LIST_ROUTE } from './DiskImageForm';
import { useTranslation } from '../../hooks/useTranslation';
import ListPage from '../Page/ListPage';

const DiskImageCreatePage = () => {
  const { t } = useTranslation();
  const navigate = useNavigate();

  return (
    <ListPage
      title={t('Create disk image')}
      breadcrumb={
        <Breadcrumb>
          <BreadcrumbItem>
            <Button variant="link" isInline onClick={() => navigate(DISK_IMAGES_LIST_ROUTE)}>
              {t('Disk images')}
            </Button>
          </BreadcrumbItem>
          <BreadcrumbItem isActive>{t('Create')}</BreadcrumbItem>
        </Breadcrumb>
      }
    >
      <DiskImageForm />
    </ListPage>
  );
};

export default DiskImageCreatePage;
