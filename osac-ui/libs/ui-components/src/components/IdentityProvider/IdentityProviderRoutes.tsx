import { Route, Routes } from 'react-router-dom';

import IdentityProviderCreatePage from './CreateWizard/IdentityProviderCreateWizard';
import IdentityProviderListPage from './IdentityProviderListPage';

const IdentityProviderRoutes = () => {
  return (
    <Routes>
      <Route index element={<IdentityProviderListPage />} />
      <Route path="create" element={<IdentityProviderCreatePage />} />
      <Route path=":id/edit" element={<IdentityProviderCreatePage />} />
    </Routes>
  );
};

export default IdentityProviderRoutes;
