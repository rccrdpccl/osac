import type { ReactNode } from 'react';
import { Link } from 'react-router-dom';
import {
  Breadcrumb,
  BreadcrumbItem,
  Content,
  Flex,
  FlexItem,
  Stack,
  StackItem,
  Title,
} from '@patternfly/react-core';

interface ResourceDetailHeaderProps {
  parentTo: string;
  parentLabel: string;
  resourceName: string;
  description?: string;
  titleAddon?: ReactNode;
}

export const ResourceDetailHeader = ({
  parentTo,
  parentLabel,
  resourceName,
  description,
  titleAddon,
}: ResourceDetailHeaderProps) => {
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
          <BreadcrumbItem isActive>{resourceName}</BreadcrumbItem>
        </Breadcrumb>
      </StackItem>

      <StackItem>
        <Stack hasGutter={false}>
          <StackItem>
            <Flex
              alignItems={{ default: 'alignItemsCenter' }}
              spaceItems={{ default: 'spaceItemsMd' }}
              flexWrap={{ default: 'wrap' }}
            >
              <FlexItem>
                <Title headingLevel="h1" size="2xl">
                  {resourceName}
                </Title>
              </FlexItem>
              {titleAddon ? <FlexItem>{titleAddon}</FlexItem> : null}
            </Flex>
          </StackItem>
          {description && (
            <StackItem>
              <Content component="p">{description}</Content>
            </StackItem>
          )}
        </Stack>
      </StackItem>
    </Stack>
  );
};
