import CloudIcon from '@patternfly/react-icons/dist/esm/icons/cloud-icon';
import ServerIcon from '@patternfly/react-icons/dist/esm/icons/server-icon';
import VirtualMachineIcon from '@patternfly/react-icons/dist/esm/icons/virtual-machine-icon';

interface CatalogItemIconProps {
  kind:
    | 'osac.public.v1.ClusterCatalogItem'
    | 'osac.public.v1.BareMetalInstanceCatalogItem'
    | 'osac.public.v1.ComputeInstanceCatalogItem';
}

export const CatalogItemIcon = ({ kind }: CatalogItemIconProps) => {
  let Icon = VirtualMachineIcon;
  switch (kind) {
    case 'osac.public.v1.ClusterCatalogItem':
      Icon = CloudIcon;
      break;
    case 'osac.public.v1.BareMetalInstanceCatalogItem':
      Icon = ServerIcon;
      break;
    default:
      Icon = VirtualMachineIcon;
  }
  return <Icon aria-hidden className="pf-v6-u-font-size-lg" />;
};
