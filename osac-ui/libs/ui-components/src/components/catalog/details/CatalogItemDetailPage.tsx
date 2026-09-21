import { useParams } from 'react-router-dom';

import CatalogItemDetails from './CatalogItemDetails.tsx';
import { useBareMetalInstanceCatalogItem } from '../../../api/v1/baremetal-instance.ts';
import { useClusterCatalogItem } from '../../../api/v1/cluster-catalog-item.ts';
import { useComputeInstanceCatalogItem } from '../../../api/v1/compute-instance-catalog-item.ts';
import { useTranslation } from '../../../hooks/useTranslation.ts';
import { ResourceDetailsPageError } from '../../Resource/ResourceDetailsPageError.tsx';
import { ResourceDetailsPageLoading } from '../../Resource/ResourceDetailsPageLoading.tsx';
import { type CatalogItemKind, isCatalogItemKind } from '../catalogItemDisplay.ts';

const useCatalogItemByKind = (kind: CatalogItemKind | undefined, id: string | undefined) => {
  const vm = useComputeInstanceCatalogItem(kind === 'vm' ? id : undefined);
  const cluster = useClusterCatalogItem(kind === 'cluster' ? id?.trim() : undefined);
  const bm = useBareMetalInstanceCatalogItem(kind === 'bm' ? id : undefined);

  switch (kind) {
    case 'vm':
      return vm;
    case 'cluster':
      return cluster;
    case 'bm':
      return bm;
    default:
      return {
        data: undefined,
        isLoading: false,
        isError: false,
        error: undefined,
        refetch: () => undefined,
      };
  }
};

export const CatalogItemDetailPage = () => {
  const { t } = useTranslation();
  const { kind: kindParam, id } = useParams() as { kind?: string; id?: string };
  const kind = isCatalogItemKind(kindParam) ? kindParam : undefined;
  const { data: item, isLoading, isError, error, refetch } = useCatalogItemByKind(kind, id);

  if (!kind || !id?.trim()) {
    return (
      <ResourceDetailsPageError
        parentTo="/catalog"
        parentLabel={t('Catalog')}
        resourceLabel={t('catalog item')}
        variant="not-found"
      />
    );
  }

  if (isLoading) {
    return (
      <ResourceDetailsPageLoading parentTo="/catalog" parentLabel={t('Catalog')} cardCount={1} />
    );
  }

  if (isError) {
    return (
      <ResourceDetailsPageError
        parentTo="/catalog"
        parentLabel={t('Catalog')}
        resourceLabel={t('catalog item')}
        error={error}
        onRetry={() => void refetch()}
      />
    );
  }

  if (!item) {
    return (
      <ResourceDetailsPageError
        parentTo="/catalog"
        parentLabel={t('Catalog')}
        resourceLabel={t('catalog item')}
        variant="not-found"
      />
    );
  }

  return <CatalogItemDetails item={item} />;
};
