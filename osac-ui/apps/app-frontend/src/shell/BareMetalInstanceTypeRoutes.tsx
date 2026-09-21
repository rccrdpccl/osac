import { Route, Routes } from 'react-router-dom';

import AdminBareMetalInstanceTypeDetailPage from '@osac/ui-components/components/BareMetalInstanceType/AdminBareMetalInstanceTypeDetailPage';
import AdminBareMetalInstanceTypeListPage from '@osac/ui-components/components/BareMetalInstanceType/AdminBareMetalInstanceTypeListPage';
import AdminBareMetalInstanceTypeCreatePage from '@osac/ui-components/components/BareMetalInstanceType/CreatePage/AdminBareMetalInstanceTypeCreatePage';

export const BareMetalInstanceTypeRoutes = () => (
  <Routes>
    <Route index element={<AdminBareMetalInstanceTypeListPage />} />
    <Route path="create" element={<AdminBareMetalInstanceTypeCreatePage />} />
    <Route path=":id" element={<AdminBareMetalInstanceTypeDetailPage />} />
    <Route path=":id/edit" element={<AdminBareMetalInstanceTypeCreatePage />} />
  </Routes>
);
