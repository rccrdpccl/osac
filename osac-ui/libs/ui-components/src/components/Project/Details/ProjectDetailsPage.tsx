import { useParams } from 'react-router-dom';
import {
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
  Divider,
  Flex,
  FlexItem,
  Grid,
  GridItem,
  PageSection,
  Stack,
  StackItem,
  Title,
} from '@patternfly/react-core';

import { Project } from '@osac/types';
import { useProject } from '@osac/ui-components/api/v1/project';
import { useTranslation } from '@osac/ui-components/hooks/useTranslation';

import ProjectDetailsActionButtons from './ProjectDetailsActionButtons';
import { Timestamp } from '../../Primitives/Timestamp';
import ProjectMembership from '../../ProjectMembership/ProjectMembershipTable';
import { ResourceDetailHeader } from '../../Resource/ResourceDetailHeader';
import ResourceDetailsPage from '../../Resource/ResourceDetailsPage';
import ProjectStatusLabel from '../ProjectStatusLabel';
import { getProjectName } from '../utils';

interface ProjectDetailsPageContentProps {
  project: Project;
}

const ProjectDetailsPageContent = ({ project }: ProjectDetailsPageContentProps) => {
  const { t } = useTranslation();

  return (
    <>
      <PageSection hasBodyWrapper={false}>
        <Stack hasGutter>
          <StackItem>
            <Flex
              justifyContent={{ default: 'justifyContentSpaceBetween' }}
              alignItems={{ default: 'alignItemsFlexStart' }}
              flexWrap={{ default: 'wrap' }}
              spaceItems={{ default: 'spaceItemsMd' }}
            >
              <FlexItem>
                <ResourceDetailHeader
                  parentTo="/projects"
                  parentLabel={t('Projects')}
                  resourceName={getProjectName(project, t)}
                  titleAddon={<ProjectStatusLabel project={project} />}
                />
              </FlexItem>
              <FlexItem>
                <ProjectDetailsActionButtons project={project} />
              </FlexItem>
            </Flex>
          </StackItem>
          <StackItem>
            <Divider />
          </StackItem>
        </Stack>
      </PageSection>

      <PageSection hasBodyWrapper={false}>
        <Grid hasGutter>
          <GridItem md={6}>
            <Stack hasGutter>
              <StackItem>
                <Title headingLevel="h5">{t('Overview')}</Title>
              </StackItem>
              <StackItem>
                <DescriptionList>
                  <DescriptionListGroup>
                    <DescriptionListTerm>{t('Description')}</DescriptionListTerm>
                    <DescriptionListDescription>
                      {project.spec?.description || '-'}
                    </DescriptionListDescription>
                  </DescriptionListGroup>
                  <DescriptionListGroup>
                    <DescriptionListTerm>{t('Created')}</DescriptionListTerm>
                    <DescriptionListDescription>
                      <Timestamp value={project.metadata?.creationTimestamp} />
                    </DescriptionListDescription>
                  </DescriptionListGroup>
                </DescriptionList>
              </StackItem>
            </Stack>
          </GridItem>
          <GridItem md={6}>
            <ProjectMembership project={project} />
          </GridItem>
        </Grid>
      </PageSection>
    </>
  );
};

const ProjectDetailsPage = () => {
  const { t } = useTranslation();
  const { id } = useParams() as { id: string };

  const { data, isLoading, error, refetch } = useProject(id);

  return (
    <ResourceDetailsPage
      error={error}
      found={!!data}
      isLoading={isLoading}
      parentLabel={t('Projects')}
      parentTo="/projects"
      refetch={refetch}
    >
      {data && <ProjectDetailsPageContent project={data} />}
    </ResourceDetailsPage>
  );
};

export default ProjectDetailsPage;
