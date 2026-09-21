import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';

import TruncatedText from './TruncatedText';

describe('TruncatedText', () => {
  it('renders short content unmodified', () => {
    render(<TruncatedText content="short text" maxCharsDisplayed={32} />);

    expect(screen.getByText('short text')).toBeInTheDocument();
  });

  it('collapses internal whitespace and trims the content', () => {
    render(<TruncatedText content={'  extra   spaces \n here  '} maxCharsDisplayed={32} />);

    expect(screen.getByText('extra spaces here')).toBeInTheDocument();
  });

  it('truncates content longer than maxCharsDisplayed with an omission marker', () => {
    render(<TruncatedText content="a very long piece of content" maxCharsDisplayed={10} />);

    const truncated = document.querySelector('.pf-v6-c-truncate__text');
    expect(truncated).not.toBeNull();
    expect(truncated?.textContent).toBe('a very lon');
    expect(document.querySelector('.pf-v6-c-truncate__omission')?.textContent).toBe('...');
  });

  it('renders an em dash fallback when content is missing', () => {
    render(<TruncatedText content={undefined} maxCharsDisplayed={32} />);

    expect(screen.getByText('—')).toBeInTheDocument();
  });

  it('renders a custom fallback when content is missing', () => {
    render(<TruncatedText content="" maxCharsDisplayed={32} fallback="No description" />);

    expect(screen.getByText('No description')).toBeInTheDocument();
  });
});
