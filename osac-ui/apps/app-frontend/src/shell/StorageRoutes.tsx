import { Navigate, Route, Routes } from 'react-router-dom';

import StorageTierCreatePage from '@osac/ui-components/components/Storage/StorageTierCreatePage';
import { StorageBackendCreatePage } from '@osac/ui-components/pages/admin/StorageBackendCreatePage';
import { StorageBackendDetailsPage } from '@osac/ui-components/pages/admin/StorageBackendDetailsPage';
import { StorageManagementPage } from '@osac/ui-components/pages/admin/StorageManagementPage';
import { StorageTierDetailsPage } from '@osac/ui-components/pages/admin/StorageTierDetailsPage';

export const StorageRoutes = () => {
  return (
    <Routes>
      <Route index element={<Navigate to="backends" replace />} />
      <Route path="backends" element={<StorageManagementPage activeTab="backends" />} />
      <Route path="backends/create" element={<StorageBackendCreatePage />} />
      <Route path="backends/:id" element={<StorageBackendDetailsPage />} />
      <Route path="backends/:id/edit" element={<StorageBackendCreatePage />} />
      <Route path="tiers" element={<StorageManagementPage activeTab="tiers" />} />
      <Route path="tiers/create" element={<StorageTierCreatePage />} />
      <Route path="tiers/:id" element={<StorageTierDetailsPage />} />
      <Route path="tiers/:id/edit" element={<StorageTierCreatePage />} />
    </Routes>
  );
};
