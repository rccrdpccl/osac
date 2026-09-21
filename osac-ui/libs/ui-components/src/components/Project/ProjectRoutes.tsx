import { Route, Routes } from 'react-router-dom';

import ProjectCreatePage from '@osac/ui-components/components/Project/CreatePage/ProjectCreatePage';
import ProjectListPage from '@osac/ui-components/components/Project/ProjectListPage';

import ProjectDetailsPage from './Details/ProjectDetailsPage';

const ProjectRoutes = () => (
  <Routes>
    <Route index element={<ProjectListPage />} />
    <Route path="create" element={<ProjectCreatePage />} />
    <Route path=":id" element={<ProjectDetailsPage />} />
  </Routes>
);

export default ProjectRoutes;
