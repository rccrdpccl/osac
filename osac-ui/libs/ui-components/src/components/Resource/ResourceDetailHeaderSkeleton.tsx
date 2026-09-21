import { Link } from 'react-router-dom';
import { Breadcrumb, BreadcrumbItem, Skeleton, Stack, StackItem } from '@patternfly/react-core';

interface ResourceDetailHeaderSkeletonProps {
  parentTo: string;
  parentLabel: string;
}

export const ResourceDetailHeaderSkeleton = ({
  parentTo,
  parentLabel,
}: ResourceDetailHeaderSkeletonProps) => {
  return (
    <Stack hasGutter>
      <StackItem>
        <Breadcrumb>
          <BreadcrumbItem
            render={({ className, ariaCurrent }) => (
              <Link className={className} aria-current={ariaCurrent} to={parentTo}>
                {parentLabel}
              </Link>
            )}
          />
          <BreadcrumbItem isActive>
            <Skeleton width="12rem" screenreaderText="Loading resource name" />
          </BreadcrumbItem>
        </Breadcrumb>
      </StackItem>

      <StackItem>
        <Skeleton fontSize="2xl" width="40%" screenreaderText="Loading resource title" />
      </StackItem>
    </Stack>
  );
};
