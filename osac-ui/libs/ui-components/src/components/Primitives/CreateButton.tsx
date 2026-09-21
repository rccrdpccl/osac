import { FC, useMemo } from 'react';
import { Link, LinkProps } from 'react-router-dom';
import { Button, ButtonProps } from '@patternfly/react-core';
import PlusIcon from '@patternfly/react-icons/dist/esm/icons/plus-icon';

interface CreateButtonProps extends ButtonProps {
  to?: string;
}

const CreateButton: FC<CreateButtonProps> = ({
  icon = <PlusIcon />,
  variant = 'primary',
  to,
  children,
  ...rest
}) => {
  const Component = useMemo(
    () => (to ? (props: LinkProps) => <Link {...props} to={to} /> : undefined),
    [to],
  );

  return (
    <Button {...rest} variant={variant} icon={icon} component={Component}>
      {children}
    </Button>
  );
};

export default CreateButton;
