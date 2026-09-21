import { BareMetalInstanceCatalogItem } from '@osac/types';

import { parseFieldDefinitionDefault } from '../../../catalogFieldDefinition';

export const getDiskImageName = (catalogItem: BareMetalInstanceCatalogItem | null) =>
  parseFieldDefinitionDefault(
    catalogItem?.fieldDefinitions.find((fd) => fd.path === 'disk_image.name')?.default,
  ) as string;
