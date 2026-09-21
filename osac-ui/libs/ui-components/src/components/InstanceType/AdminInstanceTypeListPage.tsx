import CreateButton from '@osac/ui-components/components/Primitives/CreateButton.tsx';

import AdminInstanceTypeTable from './AdminInstanceTypeTable';
import { useAdminInstanceTypes } from '../../api/v1/private/instance-type';
import { useTranslation } from '../../hooks/useTranslation';
import ListPage from '../Page/ListPage';
import ListPageBody from '../Page/ListPageBody';

const AdminInstanceTypeListPage = () => {
  const { t } = useTranslation();
  const { data: instanceTypes = [], isLoading, error } = useAdminInstanceTypes();

  return (
    <ListPage
      title={t('Instance types')}
      label={t('Infrastructure')}
      description={t('Manage provider-defined instance types for this cloud platform.')}
      error={error}
      actions={
        <CreateButton to="/admin/infrastructure/instance-types/create">
          {t('Create instance type')}
        </CreateButton>
      }
    >
      <ListPageBody isLoading={isLoading} error={error}>
        <AdminInstanceTypeTable instanceTypes={instanceTypes} />
      </ListPageBody>
    </ListPage>
  );
};

export default AdminInstanceTypeListPage;
