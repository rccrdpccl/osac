import {
  Card,
  CardBody,
  CardTitle,
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
  Flex,
  FlexItem,
  Label,
  Stack,
  StackItem,
} from '@patternfly/react-core';

import { CatalogFieldEditabilityLabel } from './CatalogFieldEditabilityLabel.tsx';
import { useTranslation } from '../../../hooks/useTranslation.ts';
import { SubtleContent } from '../../SubtleContent/SubtleContent.tsx';
import {
  type CatalogItem,
  catalogItemConfigurationFieldDefinitions,
  catalogItemMetadataLabelEntries,
  catalogItemResourceParts,
  formatCatalogFieldDefault,
} from '../catalogItemDisplay.ts';

interface CatalogItemDetailContentProps {
  item: CatalogItem;
}

export const CatalogItemDetailContent = ({ item }: CatalogItemDetailContentProps) => {
  const { t } = useTranslation();
  const resources = catalogItemResourceParts(item);
  const metadataLabels = catalogItemMetadataLabelEntries(item);
  const configurationFields = catalogItemConfigurationFieldDefinitions(item);
  const description = item.description?.trim();

  return (
    <Stack hasGutter>
      <StackItem>
        <Card>
          <CardTitle>{t('Details')}</CardTitle>
          <CardBody>
            <DescriptionList isHorizontal>
              <DescriptionListGroup>
                <DescriptionListTerm>{t('Catalog name')}</DescriptionListTerm>
                <DescriptionListDescription>
                  {item.metadata?.name ?? '—'}
                </DescriptionListDescription>
              </DescriptionListGroup>

              {description ? (
                <DescriptionListGroup>
                  <DescriptionListTerm>{t('Description')}</DescriptionListTerm>
                  <DescriptionListDescription>{description}</DescriptionListDescription>
                </DescriptionListGroup>
              ) : null}

              {resources.length > 0 ? (
                <DescriptionListGroup>
                  <DescriptionListTerm>{t('Default resources')}</DescriptionListTerm>
                  <DescriptionListDescription>
                    <Flex flexWrap={{ default: 'wrap' }} gap={{ default: 'gapSm' }}>
                      {resources.map((resource, index) => (
                        <FlexItem key={`${item.id}-detail-resource-${index}`}>
                          <Label variant="outline" color="blue" isCompact>
                            {resource}
                          </Label>
                        </FlexItem>
                      ))}
                    </Flex>
                  </DescriptionListDescription>
                </DescriptionListGroup>
              ) : null}

              {metadataLabels.length > 0 ? (
                <DescriptionListGroup>
                  <DescriptionListTerm>{t('Labels')}</DescriptionListTerm>
                  <DescriptionListDescription>
                    <Flex flexWrap={{ default: 'wrap' }} gap={{ default: 'gapSm' }}>
                      {metadataLabels.map(({ key, value }) => (
                        <FlexItem key={`${item.id}-detail-label-${key}`}>
                          <Label variant="outline" color="grey" isCompact>
                            <b>{key}</b>
                            {': '}
                            {value}
                          </Label>
                        </FlexItem>
                      ))}
                    </Flex>
                  </DescriptionListDescription>
                </DescriptionListGroup>
              ) : null}
            </DescriptionList>
          </CardBody>
        </Card>
      </StackItem>

      {configurationFields.length > 0 ? (
        <StackItem>
          <Card>
            <CardTitle>{t('Configuration defaults')}</CardTitle>
            <CardBody>
              <Stack hasGutter>
                <StackItem>
                  <SubtleContent component="p">
                    {t(
                      'Editable fields can be changed when creating from this catalog item. Fixed fields use the default value shown.',
                    )}
                  </SubtleContent>
                </StackItem>
                <StackItem>
                  <DescriptionList isHorizontal>
                    {configurationFields.map((def) => (
                      <DescriptionListGroup key={def.path}>
                        <DescriptionListTerm>
                          {def.displayName} <CatalogFieldEditabilityLabel editable={def.editable} />
                        </DescriptionListTerm>
                        <DescriptionListDescription>
                          {formatCatalogFieldDefault(def)}
                        </DescriptionListDescription>
                      </DescriptionListGroup>
                    ))}
                  </DescriptionList>
                </StackItem>
              </Stack>
            </CardBody>
          </Card>
        </StackItem>
      ) : null}
    </Stack>
  );
};
