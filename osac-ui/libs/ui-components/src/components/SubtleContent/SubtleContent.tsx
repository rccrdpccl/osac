import type { ComponentProps } from 'react';
import { Content } from '@patternfly/react-core';

import './SubtleContent.css';

type SubtleContentProps = ComponentProps<typeof Content>;

export const SubtleContent = ({ className, ...props }: SubtleContentProps) => {
  return (
    <Content {...props} className={['osac-subtle-content', className].filter(Boolean).join(' ')} />
  );
};
