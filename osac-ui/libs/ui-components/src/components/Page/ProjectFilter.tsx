import { useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import {
  Alert,
  Divider,
  MenuToggle,
  Select,
  SelectList,
  SelectOption,
  Skeleton,
} from '@patternfly/react-core';

import { Project } from '@osac/types';
import { useAllProjects } from '@osac/ui-components/api/v1/project';
import { serializePageFilter } from '@osac/ui-components/hooks/use-page-filter';
import { PROJECT_FILTER_PARAM, useSession } from '@osac/ui-components/hooks/use-session';
import { getErrorMessage } from '@osac/ui-components/utils/error';

import { useTranslation } from '../../hooks/useTranslation';
import { getFullProjectPath, getProjectName } from '../Project/utils';

const ProjectFilter = () => {
  const { t } = useTranslation();
  const { projects, setProjects } = useSession();
  const [isOpen, setIsOpen] = useState(false);
  const { data, isLoading, error } = useAllProjects();
  const [searchParams, setSearchParams] = useSearchParams();

  useEffect(() => {
    if (projects !== undefined) {
      const serialized = serializePageFilter(projects);
      if (!serialized) {
        setSearchParams(
          (prev) => {
            const next = new URLSearchParams(prev);
            next.delete(PROJECT_FILTER_PARAM);
            return next;
          },
          { replace: true },
        );
        return;
      }

      setSearchParams(
        (prev) => {
          const next = new URLSearchParams(prev);
          next.set(PROJECT_FILTER_PARAM, serialized);
          return next;
        },
        { replace: true },
      );
    }
  }, [searchParams, setSearchParams, projects]);

  const selectedProjects: Project[] = [];

  projects.forEach((p) => {
    const project = data?.find((d) => getFullProjectPath(d) === p);
    if (project) {
      selectedProjects.push(project);
    }
  });

  const hasAllProjects = projects.length === selectedProjects.length;

  useEffect(() => {
    if (!isLoading && !hasAllProjects) {
      setProjects(selectedProjects.map(getFullProjectPath));
    }
    // trigger based on hasAllProjects + isLoading only
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [hasAllProjects, isLoading]);

  let items = (
    <>
      {data?.map((p) => (
        <SelectOption
          key={p.id}
          hasCheckbox
          isSelected={projects.includes(getFullProjectPath(p))}
          value={getFullProjectPath(p)}
        >
          {getProjectName(p, t)}
        </SelectOption>
      ))}
    </>
  );

  if (isLoading) {
    items = (
      <>
        <SelectOption isDisabled>
          <Skeleton />
        </SelectOption>
        <SelectOption isDisabled>
          <Skeleton />
        </SelectOption>
        <SelectOption isDisabled>
          <Skeleton />
        </SelectOption>
      </>
    );
  }

  if (error) {
    items = (
      <Alert title={t('Failed to fetch projects')} variant="danger" isInline>
        {getErrorMessage(error)}
      </Alert>
    );
  }

  return (
    <Select
      isOpen={isOpen}
      onSelect={(_, val: string) => {
        if (val === null) {
          setProjects([]);
          setIsOpen(false);
        } else {
          setProjects(
            projects.includes(val) ? projects.filter((p) => p !== val) : [...projects, val],
          );
        }
      }}
      onOpenChange={() => setIsOpen((o) => !o)}
      toggle={(toggleRef) => (
        <MenuToggle ref={toggleRef} onClick={() => setIsOpen((o) => !o)} isExpanded={isOpen}>
          {selectedProjects.length
            ? selectedProjects.map((p) => getProjectName(p, t)).join(', ')
            : t('All projects')}
        </MenuToggle>
      )}
      shouldFocusToggleOnSelect
    >
      <SelectList>
        <SelectOption value={null}>{t('All projects')}</SelectOption>
        <Divider />
        {items}
      </SelectList>
    </Select>
  );
};

export default ProjectFilter;
