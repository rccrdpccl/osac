import { Route, Routes } from 'react-router-dom';

import { ExternalIpPoolDetailsPage } from './ExternalIpPoolDetailsPage';
import { ExternalIpPoolsListPage } from './ExternalIpPoolsListPage';
import { ExternalIpPoolWizardPage } from './ExternalIpPoolWizardPage';

export const ExternalIpPoolRoutes = () => (
  <Routes>
    <Route index element={<ExternalIpPoolsListPage />} />
    <Route path="create" element={<ExternalIpPoolWizardPage />} />
    <Route path=":id" element={<ExternalIpPoolDetailsPage />} />
  </Routes>
);
