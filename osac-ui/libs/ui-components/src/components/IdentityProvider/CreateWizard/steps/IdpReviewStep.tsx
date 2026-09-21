import {
  DescriptionList,
  DescriptionListDescription,
  DescriptionListGroup,
  DescriptionListTerm,
  Stack,
  StackItem,
  Title,
} from '@patternfly/react-core';
import { useFormikContext } from 'formik';

import { useTranslation } from '../../../../hooks/useTranslation';
import { IdentityProviderValues } from '../values';

const IdpReviewStep = () => {
  const { t } = useTranslation();
  const { values } = useFormikContext<IdentityProviderValues>();

  return (
    <Stack hasGutter>
      <StackItem>
        <Title headingLevel="h2" size="lg">
          {t('Review')}
        </Title>
      </StackItem>
      <StackItem>
        <DescriptionList isHorizontal isCompact aria-label={t('Review')}>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Name')}</DescriptionListTerm>
            <DescriptionListDescription>{values.metadata.name}</DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Title')}</DescriptionListTerm>
            <DescriptionListDescription>{values.spec.title || '-'}</DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Description')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.description || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>

          <DescriptionListGroup>
            <DescriptionListTerm>{t('Client ID')}</DescriptionListTerm>
            <DescriptionListDescription>{values.spec.config.clientId}</DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Client secret')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.clientSecretSecret.name}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Issuer')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.issuer || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Authorization URL')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.authorizationUrl || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Token URL')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.tokenUrl || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Default scopes')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.defaultScopes || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('User info URL')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.userInfoUrl || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('JWKS URL')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.jwksUrl || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>
          <DescriptionListGroup>
            <DescriptionListTerm>{t('Logout URL')}</DescriptionListTerm>
            <DescriptionListDescription>
              {values.spec.config.logoutUrl || '-'}
            </DescriptionListDescription>
          </DescriptionListGroup>
        </DescriptionList>
      </StackItem>
    </Stack>
  );
};

export default IdpReviewStep;
