import { Route, Routes } from 'react-router-dom';

import ProjectMembershipCreatePage from './CreatePage/ProjectMembershipCreatePage';

const ProjectMembershipRoutes = () => (
  <Routes>
    <Route path="edit/:projectId/:pmId" element={<ProjectMembershipCreatePage />} />
    <Route path="create/:projectId" element={<ProjectMembershipCreatePage />} />
  </Routes>
);

export default ProjectMembershipRoutes;
