import { useNavigate } from 'react-router-dom';
import { Button, Flex, FlexItem, PageSection, Stack, StackItem } from '@patternfly/react-core';

import { CatalogItemDetailContent } from './CatalogItemDetailContent.tsx';
import { useTranslation } from '../../../hooks/useTranslation';
import { ResourceDetailHeader } from '../../Resource/ResourceDetailHeader';
import { CatalogItem, getCatalogCreateAction } from '../catalogItemDisplay';

interface CatalogItemDetailsProps {
  item: CatalogItem;
}

const CatalogItemDetails = ({ item }: CatalogItemDetailsProps) => {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const createAction = getCatalogCreateAction(item, t);

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
                  parentTo="/catalog"
                  parentLabel={t('Catalog')}
                  resourceName={item.title}
                />
              </FlexItem>
              <FlexItem>
                <Button variant="primary" onClick={() => navigate(createAction.path)}>
                  {createAction.label}
                </Button>
              </FlexItem>
            </Flex>
          </StackItem>
        </Stack>
      </PageSection>
      <PageSection hasBodyWrapper={false}>
        <CatalogItemDetailContent item={item} />
      </PageSection>
    </>
  );
};

export default CatalogItemDetails;
