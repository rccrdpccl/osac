import { Label } from '@patternfly/react-core';

export type LifecycleKind = 'active' | 'deprecated' | 'obsolete' | 'unspecified';

type LifecycleLabelColor = 'green' | 'orange' | 'grey';

const LIFECYCLE_COLOR: Record<LifecycleKind, LifecycleLabelColor> = {
  active: 'green',
  deprecated: 'orange',
  obsolete: 'grey',
  unspecified: 'grey',
};

export interface ResourceLifecycleLabelProps {
  lifecycle: LifecycleKind;
  text: string;
}

export const ResourceLifecycleLabel = ({ lifecycle, text }: ResourceLifecycleLabelProps) => {
  return <Label color={LIFECYCLE_COLOR[lifecycle]}>{text}</Label>;
};
