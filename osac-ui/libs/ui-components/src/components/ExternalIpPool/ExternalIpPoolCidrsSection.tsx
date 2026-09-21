import { useState } from 'react';
import { Button, List, ListItem, Stack, StackItem, Title } from '@patternfly/react-core';

import { useTranslation } from '../../hooks/useTranslation';
import { SubtleContent } from '../SubtleContent/SubtleContent';

const CIDR_PREVIEW_COUNT = 1;

interface ExternalIpPoolCidrsSectionProps {
  cidrs: string[];
}

const ExternalIpPoolCidrsSection = ({ cidrs }: ExternalIpPoolCidrsSectionProps) => {
  const { t } = useTranslation();
  const [isExpanded, setIsExpanded] = useState(false);
  const canToggle = cidrs.length > CIDR_PREVIEW_COUNT;
  const visibleCidrs = canToggle && !isExpanded ? cidrs.slice(0, CIDR_PREVIEW_COUNT) : cidrs;

  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('CIDRs')}
        </Title>
      </StackItem>
      <StackItem>
        {cidrs.length === 0 ? (
          <SubtleContent component="p">{t('No CIDRs')}</SubtleContent>
        ) : (
          <Stack>
            <StackItem>
              <List isPlain aria-label={t('CIDRs')}>
                {visibleCidrs.map((cidr, index) => (
                  <ListItem key={`${cidr}-${index}`}>{cidr}</ListItem>
                ))}
              </List>
            </StackItem>
            {canToggle && (
              <StackItem>
                <Button
                  variant="link"
                  isInline
                  size="sm"
                  onClick={() => setIsExpanded((expanded) => !expanded)}
                >
                  {isExpanded ? t('Show less') : t('More')}
                </Button>
              </StackItem>
            )}
          </Stack>
        )}
      </StackItem>
    </Stack>
  );
};

export default ExternalIpPoolCidrsSection;
