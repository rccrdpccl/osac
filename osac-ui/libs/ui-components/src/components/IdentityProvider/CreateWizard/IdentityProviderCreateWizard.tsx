import { useCallback, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import {
  Alert,
  Breadcrumb,
  BreadcrumbItem,
  Bullseye,
  Button,
  PageSection,
  PageSectionTypes,
  Spinner,
  Title,
  Wizard,
  WizardStep,
} from '@patternfly/react-core';
import { Formik } from 'formik';

import { IdentityProvider, IdentityProviders } from '@osac/types';
import {
  useCreateResource,
  useGetResource,
  useUpdateResource,
} from '@osac/ui-components/api/use-resource';
import { getErrorMessage } from '@osac/ui-components/utils/error';

import { buildIdpCreatePayload, buildIdpUpdatePayload } from './payload';
import IdpConfigurationStep from './steps/IdpConfigurationStep';
import IdpGeneralStep from './steps/IdpGeneralStep';
import IdpReviewStep from './steps/IdpReviewStep';
import { getIdentityProviderSchema, idpStepHasErrors } from './validation';
import { IdentityProviderValues, getIdentityProviderValues } from './values';
import { useTranslation } from '../../../hooks/useTranslation';
import { FieldValidationProvider } from '../../Form/FieldValidationContext';
import LeaveFormConfirmation from '../../Form/LeaveFormConfirmation';
import { OSACWizardFooter } from '../../Wizard/OSACWizardFooter';

interface IdentityProviderCreateWizard {
  idp?: IdentityProvider;
}

const IdentityProviderCreateWizard = ({ idp }: IdentityProviderCreateWizard) => {
  const { t } = useTranslation();

  const navigate = useNavigate();
  const {
    mutateAsync: createAync,
    error: createErr,
    reset: resetCreate,
  } = useCreateResource(IdentityProviders);
  const {
    mutateAsync: updateAsync,
    error: updateErr,
    reset: resetUpdate,
  } = useUpdateResource(IdentityProviders);
  const [currentStep, setCurrentStep] = useState<string>('general');

  const handleErrorReset = useCallback(() => {
    resetCreate();
    resetUpdate();
  }, [resetCreate, resetUpdate]);

  const initialValues = getIdentityProviderValues(idp);

  const onSubmit = async (values: IdentityProviderValues) => {
    try {
      if (idp) {
        await updateAsync({
          object: {
            id: idp.id,
            ...buildIdpUpdatePayload(values),
          },
        });
      } else {
        await createAync({ object: buildIdpCreatePayload(values) });
      }
      navigate(`/tenant/identity-provider`);
    } catch {
      // nothing to do, tanstack handles the error
    }
  };

  return (
    <Formik<IdentityProviderValues>
      initialValues={initialValues}
      validationSchema={getIdentityProviderSchema(t, !!idp)}
      onSubmit={onSubmit}
    >
      <>
        <PageSection hasBodyWrapper={false}>
          <Breadcrumb>
            <BreadcrumbItem>
              <Button variant="link" isInline onClick={() => navigate('/tenant/identity-provider')}>
                {t('Identity providers')}
              </Button>
            </BreadcrumbItem>
            <BreadcrumbItem isActive>
              {idp ? t('Edit Identity provider') : t('Create Identity provider')}
            </BreadcrumbItem>
          </Breadcrumb>
          <Title headingLevel="h1" size="3xl">
            {idp ? t('Edit Identity provider') : t('Create Identity provider')}
          </Title>
        </PageSection>
        <FieldValidationProvider>
          <LeaveFormConfirmation />
          <PageSection
            hasBodyWrapper={false}
            type={PageSectionTypes.wizard}
            aria-label={t('Identity provider create wizard')}
          >
            <Wizard
              navAriaLabel={t('Create Identity provider steps')}
              isVisitRequired
              footer={
                <OSACWizardFooter
                  onCancel={() => navigate('/tenant/identity-provider')}
                  stepHasErrors={idpStepHasErrors}
                  isEdit={!!idp}
                  error={createErr || updateErr}
                  onErrorReset={handleErrorReset}
                />
              }
              onStepChange={(_, step) => {
                setCurrentStep(step.id as string);
              }}
            >
              <WizardStep id="general" name={t('General')}>
                {currentStep === 'general' && <IdpGeneralStep isEdit={!!idp} />}
              </WizardStep>
              <WizardStep id="configuration" name={t('Configuration')}>
                {currentStep === 'configuration' && <IdpConfigurationStep />}
              </WizardStep>
              <WizardStep id="review" name={t('Review')}>
                {currentStep === 'review' && <IdpReviewStep />}
              </WizardStep>
            </Wizard>
          </PageSection>
        </FieldValidationProvider>
      </>
    </Formik>
  );
};

const IdentityProviderCreatePage = () => {
  const { t } = useTranslation();
  const { id } = useParams<{ id: string }>();

  const { data, isLoading, error } = useGetResource(
    IdentityProviders,
    { id: id ?? '' },
    { enabled: Boolean(id) },
  );

  if (isLoading) {
    return (
      <Bullseye>
        <Spinner />
      </Bullseye>
    );
  }

  if (error) {
    return (
      <Alert variant="danger" isInline title={t('Failed to fetch Identity provider')}>
        {getErrorMessage(error)}
      </Alert>
    );
  }

  return <IdentityProviderCreateWizard idp={data?.object} />;
};

export default IdentityProviderCreatePage;
