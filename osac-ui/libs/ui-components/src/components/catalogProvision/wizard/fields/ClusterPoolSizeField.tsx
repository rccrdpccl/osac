import { useTranslation } from '../../../../hooks/useTranslation';
import { InputField } from '../../../Form/InputField';

interface ClusterPoolSizeFieldProps {
  rowIndex: number;
  isRequired?: boolean;
}

const ClusterPoolSizeField = ({ rowIndex, isRequired = false }: ClusterPoolSizeFieldProps) => {
  const { t } = useTranslation();

  return (
    <InputField
      name={`spec.nodeSetRows.${rowIndex}.size`}
      label={t('Nodes')}
      fieldId={`cluster-node-set-size-${rowIndex}`}
      isRequired={isRequired}
      type="number"
    />
  );
};

export default ClusterPoolSizeField;
