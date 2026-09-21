import { useNavigate } from 'react-router-dom';
import {
  Bullseye,
  Gallery,
  GalleryItem,
  Spinner,
  Stack,
  StackItem,
  Title,
} from '@patternfly/react-core';

import CatalogItemCard from './CatalogItemCard';
import type { CatalogItem } from './catalogItemDisplay';
import { getErrorMessage } from '../../utils/error';
import QueryErrorState from '../Resource/QueryErrorState';

const itemRoute: Record<CatalogItem['$typeName'], string> = {
  'osac.public.v1.ClusterCatalogItem': 'cluster',
  'osac.public.v1.BareMetalInstanceCatalogItem': 'bm',
  'osac.public.v1.ComputeInstanceCatalogItem': 'vm',
};

interface CatalogItemListSectionProps {
  title?: string;
  items: CatalogItem[];
  isLoading?: boolean;
  error?: unknown;
}

export const CatalogItemListSection = ({
  title,
  items,
  isLoading = false,
  error = null,
}: CatalogItemListSectionProps) => {
  const navigate = useNavigate();
  if (!isLoading && !error && items.length === 0) {
    return null;
  }

  return (
    <StackItem>
      <Stack hasGutter>
        {title ? (
          <StackItem>
            <Title headingLevel="h2" size="lg">
              {title}
            </Title>
          </StackItem>
        ) : null}
        {isLoading ? (
          <StackItem>
            <Bullseye>
              <Spinner aria-label={`Loading ${title}`} />
            </Bullseye>
          </StackItem>
        ) : null}
        {error ? (
          <StackItem>
            <QueryErrorState error={error} title={title} body={getErrorMessage(error)} />
          </StackItem>
        ) : null}
        {items.length > 0 ? (
          <StackItem>
            <Gallery hasGutter minWidths={{ default: '400px' }} maxWidths={{ default: '400px' }}>
              {items.map((item) => (
                <GalleryItem key={item.id}>
                  <CatalogItemCard
                    item={item}
                    onOpenDetails={() =>
                      navigate(`/catalog/${itemRoute[item.$typeName]}/${item.id}`)
                    }
                  />
                </GalleryItem>
              ))}
            </Gallery>
          </StackItem>
        ) : null}
      </Stack>
    </StackItem>
  );
};
