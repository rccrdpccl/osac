import { useNavigate } from 'react-router-dom';
import {
  Button,
  Card,
  CardBody,
  CardHeader,
  CardTitle,
  Content,
  Divider,
  Flex,
  FlexItem,
  Label,
  Stack,
  StackItem,
} from '@patternfly/react-core';
import RocketIcon from '@patternfly/react-icons/dist/esm/icons/rocket-icon';

import { CatalogItem, getCatalogCreateAction } from './catalogItemDisplay';
import { catalogItemTypeBadgeLabel } from './catalogItemDisplay';
import {
  catalogItemMetadataLabelEntries,
  catalogItemResourceParts,
  catalogItemSubtitle,
} from './catalogItemDisplay';
import { useTranslation } from '../../hooks/useTranslation';
import { CatalogItemIcon } from '../../icons';

export interface CatalogItemCardSelection {
  selected: boolean;
  onSelect: () => void;
}

interface CatalogItemCardProps {
  item: CatalogItem;
  selection?: CatalogItemCardSelection;
  onOpenDetails?: () => void;
}

const CatalogItemCard = ({ item, selection, onOpenDetails }: CatalogItemCardProps) => {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const resources = catalogItemResourceParts(item);
  const metadataLabels = catalogItemMetadataLabelEntries(item);
  const subtitle = catalogItemSubtitle(item);
  const isBrowseMode = Boolean(onOpenDetails && !selection);
  const isWizardMode = Boolean(selection);
  const cardId = `catalog-item-card-${item.id}`;
  const titleId = `${cardId}-title`;

  const createAction = getCatalogCreateAction(item, t);

  return (
    <Card
      id={cardId}
      ouiaId={`catalog-item-option-${item.id}`}
      isSelectable={isWizardMode}
      isClickable={isBrowseMode}
      isSelected={selection?.selected}
      isFullHeight
    >
      <CardHeader
        actions={{
          actions: !isWizardMode ? (
            <Label color="blue" isCompact>
              {catalogItemTypeBadgeLabel(item, t)}
            </Label>
          ) : null,
        }}
        selectableActions={
          isWizardMode && selection
            ? {
                variant: 'single',
                name: 'selectedCatalogItem',
                selectableActionId: `selectedCatalogItem-${item.id}`,
                selectableActionAriaLabel: item.title,
                hasNoOffset: true,
                onChange: () => {
                  selection.onSelect();
                },
              }
            : isBrowseMode
              ? {
                  selectableActionAriaLabel: t('Open catalog item details for {{title}}', {
                    title: item.title,
                  }),
                  onClickAction: () => {
                    onOpenDetails?.();
                  },
                }
              : undefined
        }
      >
        <Flex alignItems={{ default: 'alignItemsFlexStart' }} gap={{ default: 'gapSm' }}>
          <FlexItem>
            <CatalogItemIcon kind={item.$typeName} />
          </FlexItem>
          <FlexItem flex={{ default: 'flex_1' }}>
            <CardTitle id={titleId}>{item.title}</CardTitle>
          </FlexItem>
        </Flex>
      </CardHeader>
      <Divider />
      <CardBody>
        <Stack hasGutter>
          <StackItem>
            <Content component="small" className="pf-v6-u-color-text-subtle">
              {subtitle}
            </Content>
          </StackItem>
          {resources.length > 0 ? (
            <StackItem>
              <Flex flexWrap={{ default: 'wrap' }} gap={{ default: 'gapSm' }}>
                {resources.map((resource, index) => (
                  <FlexItem key={`${item.id}-resource-${index}`}>
                    <Label variant="outline" color="blue" isCompact>
                      {resource}
                    </Label>
                  </FlexItem>
                ))}
              </Flex>
            </StackItem>
          ) : null}
          <StackItem>
            <Divider />
          </StackItem>
          {metadataLabels.length > 0 ? (
            <StackItem>
              <Flex flexWrap={{ default: 'wrap' }} gap={{ default: 'gapSm' }}>
                {metadataLabels.map(({ key, value }) => (
                  <FlexItem key={`${item.id}-label-${key}`}>
                    <Label variant="outline" color="grey" isCompact>
                      <b>{key}</b>
                      {': '}
                      {value}
                    </Label>
                  </FlexItem>
                ))}
              </Flex>
            </StackItem>
          ) : null}
          {!isWizardMode && (
            <StackItem>
              <Button
                variant="primary"
                isBlock
                icon={<RocketIcon />}
                onClick={(event) => {
                  event.stopPropagation();
                  navigate(createAction.path);
                }}
              >
                {createAction.label}
              </Button>
            </StackItem>
          )}
        </Stack>
      </CardBody>
    </Card>
  );
};

export default CatalogItemCard;
