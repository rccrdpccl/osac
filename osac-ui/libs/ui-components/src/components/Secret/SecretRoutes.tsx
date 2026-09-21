import { Route, Routes } from 'react-router-dom';

import SecretCreatePage from './CreatePage/SecretCreateWizard';
import SecretDetailsPage from './Details/SecretDetailsPage';
import SecretListPage from './SecretListPage';

const SecretRoutes = () => {
  return (
    <Routes>
      <Route index element={<SecretListPage />} />
      <Route path="create" element={<SecretCreatePage />} />
      <Route path=":id" element={<SecretDetailsPage />} />
      <Route path=":id/edit" element={<SecretCreatePage />} />
    </Routes>
  );
};

export default SecretRoutes;
