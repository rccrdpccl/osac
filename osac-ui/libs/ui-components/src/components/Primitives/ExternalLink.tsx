import type { ReactNode } from 'react';
import { Button } from '@patternfly/react-core';

import { toSafeExternalUrl } from '../../utils/safeExternalUrl';

interface ExternalLinkProps {
  href?: string;
  children?: ReactNode;
  fallback?: ReactNode;
  /** When the URL fails validation, render the raw value as plain text instead of the fallback. */
  showUnsafeAsText?: boolean;
}

const ExternalLink = ({
  href,
  children,
  fallback = '—',
  showUnsafeAsText = false,
}: ExternalLinkProps) => {
  const safeHref = toSafeExternalUrl(href);
  const label = children ?? href;

  if (safeHref) {
    return (
      <Button
        variant="link"
        isInline
        component="a"
        href={safeHref}
        target="_blank"
        rel="noopener noreferrer"
      >
        {label}
      </Button>
    );
  }

  if (showUnsafeAsText && href) {
    return <>{href}</>;
  }

  return <>{fallback}</>;
};

export default ExternalLink;
