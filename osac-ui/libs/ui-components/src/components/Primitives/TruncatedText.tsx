import { Truncate } from '@patternfly/react-core';

export interface TruncatedTextProps {
  content?: string | null;
  maxCharsDisplayed: number;
  fallback?: string;
  omissionContent?: string;
}

const TruncatedText = ({
  content,
  maxCharsDisplayed,
  fallback = '—',
  omissionContent = '...',
}: TruncatedTextProps) => {
  const normalized = (content || '').replace(/\s+/g, ' ').trim();

  if (!normalized) {
    return <>{fallback}</>;
  }

  return (
    <Truncate
      content={normalized}
      maxCharsDisplayed={maxCharsDisplayed}
      omissionContent={omissionContent}
    />
  );
};

export default TruncatedText;
