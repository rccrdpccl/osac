import { Route, Routes } from 'react-router-dom';

import RoleBindingCreatePage from './CreatePage/RoleBindingCreatePage';
import RoleBindingsPage from './RoleBindingsPage';

const RoleBindingRoutes = () => {
  return (
    <Routes>
      <Route index element={<RoleBindingsPage />} />
      <Route path="create" element={<RoleBindingCreatePage />} />
      <Route path=":id/edit" element={<RoleBindingCreatePage />} />
    </Routes>
  );
};

export default RoleBindingRoutes;
