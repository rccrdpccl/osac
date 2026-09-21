import { Content, Stack, StackItem, Title } from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import { Tenants } from '@osac/types/private';
import OsacForm from '@osac/ui-components/components/Form/OsacForm';
import { ResourceSelectField } from '@osac/ui-components/components/Form/ResourceSelectField';
import { useTranslation } from '@osac/ui-components/hooks/useTranslation';

import type { ExternalIpPoolFormValues } from './values';

const TenantStep = () => {
  const { t } = useTranslation();
  const { values } = useFormikContext<ExternalIpPoolFormValues>();
  const selectedTenantName = values.metadata.tenant.name;

  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Tenant')}
        </Title>
      </StackItem>
      <StackItem>
        <Content component="p">
          {t(
            'Assign this pool to a tenant. Tenants can have multiple pools for different regions or environments.',
          )}
        </Content>
      </StackItem>
      <StackItem>
        <OsacForm>
          <ResourceSelectField
            name="metadata.tenant"
            label={t('Tenant')}
            fieldId="external-ip-pool-tenant"
            service={Tenants}
            isRequired
            autoSelectSingleOption
            placeholder={t('Select a tenant')}
            loadErrorTitle={t('Failed to fetch tenants')}
            emptyTitle={t('No registered tenants')}
            emptyDescription={t(
              'Register a tenant before creating and assigning an external IP pool.',
            )}
          />
          {selectedTenantName ? (
            <Content component="p">
              {t('{{tenant}} will receive this address pool for tenant edge exposure.', {
                tenant: selectedTenantName,
              })}
            </Content>
          ) : null}
        </OsacForm>
      </StackItem>
    </Stack>
  );
};

export default TenantStep;
