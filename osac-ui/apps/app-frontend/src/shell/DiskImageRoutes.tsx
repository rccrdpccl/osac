import { Route, Routes } from 'react-router-dom';

import DiskImageCreatePage from '@osac/ui-components/components/DiskImage/DiskImageCreatePage';
import DiskImageDetailPage from '@osac/ui-components/components/DiskImage/DiskImageDetailPage';
import DiskImageListPage from '@osac/ui-components/components/DiskImage/DiskImageListPage';

export const DiskImageRoutes = () => (
  <Routes>
    <Route index element={<DiskImageListPage />} />
    <Route path="create" element={<DiskImageCreatePage />} />
    <Route path=":id" element={<DiskImageDetailPage />} />
  </Routes>
);
