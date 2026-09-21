import { Label } from '@patternfly/react-core';

import { useTranslation } from '../../../hooks/useTranslation.ts';

interface CatalogFieldEditabilityLabelProps {
  editable: boolean;
}

export const CatalogFieldEditabilityLabel = ({ editable }: CatalogFieldEditabilityLabelProps) => {
  const { t } = useTranslation();

  return editable ? (
    <Label variant="outline" color="green" isCompact>
      {t('Editable')}
    </Label>
  ) : (
    <Label variant="outline" color="grey" isCompact>
      {t('Fixed')}
    </Label>
  );
};
