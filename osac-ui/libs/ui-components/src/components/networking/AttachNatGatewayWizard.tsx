import { useMemo, useState } from 'react';
import {
  Breadcrumb,
  BreadcrumbItem,
  Button,
  PageSection,
  PageSectionTypes,
  Stack,
  StackItem,
  Title,
  Wizard,
  WizardStep,
} from '@patternfly/react-core';
import { Formik } from 'formik';
import type { FormikErrors } from 'formik';
import type { TFunction } from 'i18next';
import * as Yup from 'yup';

import { ExternalIPState, ExternalIPs, NATGateways } from '@osac/types';

import AttachNatGatewayReviewStep from './AttachNatGatewayReviewStep';
import AttachNatGatewayStep from './AttachNatGatewayStep';
import type {
  AttachNatGatewayFormValues,
  AttachNatGatewayVirtualNetwork,
} from './AttachNatGatewayWizard.types';
import {
  useCreateResource,
  useInvalidateServiceQueries,
  useListResource,
} from '../../api/use-resource';
import { unallocatedExternalIpFilter } from '../../api/v1/networking';
import { useTranslation } from '../../hooks/useTranslation';
import { resourceNameSchema } from '../../validation/resource-name';
import { FieldValidationProvider } from '../Form/FieldValidationContext';
import { OSACWizardFooter } from '../Wizard/OSACWizardFooter';

export interface AttachNatGatewayWizardProps {
  virtualNetwork: AttachNatGatewayVirtualNetwork;
  onClose: () => void;
}

export const attachNatGatewayStepHasErrors = (
  stepId: string,
  errors: FormikErrors<AttachNatGatewayFormValues>,
): boolean => {
  if (stepId !== 'nat-gateway') {
    return false;
  }

  return Boolean(errors.metadata?.name || errors.externalIpId);
};

const validationSchema = (t: TFunction) =>
  Yup.object({
    metadata: Yup.object({
      name: resourceNameSchema(t),
    }),
    externalIpId: Yup.string().required(t('An external IP is required')),
  });

export const AttachNatGatewayWizard = ({
  virtualNetwork,
  onClose,
}: AttachNatGatewayWizardProps) => {
  const { t } = useTranslation();
  const [currentStep, setCurrentStep] = useState('nat-gateway');
  const invalidateService = useInvalidateServiceQueries();
  const {
    data: externalIpResponse,
    isLoading: isLoadingExternalIps,
    error: externalIpsError,
  } = useListResource(ExternalIPs, { filter: unallocatedExternalIpFilter() });
  const {
    data: natGatewayResponse,
    isLoading: isLoadingNatGateways,
    error: natGatewayError,
  } = useListResource(NATGateways);
  const createNatGateway = useCreateResource(NATGateways, {
    onSuccess: async () => {
      await invalidateService(ExternalIPs);
    },
  });
  const usedExternalIpIds = useMemo(
    () =>
      new Set(
        (natGatewayResponse?.items ?? [])
          .map((gateway) => gateway.spec?.externalIp?.id)
          .filter((id): id is string => Boolean(id)),
      ),
    [natGatewayResponse?.items],
  );
  const hasNatGateway = (natGatewayResponse?.items ?? []).some(
    (gateway) => gateway.spec?.virtualNetwork?.id === virtualNetwork.id,
  );

  const externalIpOptions = useMemo(
    () =>
      (externalIpResponse?.items ?? [])
        .filter(
          (ip) =>
            ip.id &&
            ip.status?.state === ExternalIPState.EXTERNAL_IP_STATE_ALLOCATED &&
            !usedExternalIpIds.has(ip.id),
        )
        .map((ip) => ({
          value: ip.id,
          label: `${ip.metadata?.name ?? ip.id} · ${ip.status?.address ?? '—'}`,
        })),
    [externalIpResponse?.items, usedExternalIpIds],
  );

  const noExternalIpsAvailable =
    !isLoadingExternalIps && !externalIpsError && externalIpOptions.length === 0;

  const handleClose = () => {
    setCurrentStep('nat-gateway');
    onClose();
  };

  return (
    <Formik<AttachNatGatewayFormValues>
      initialValues={{
        metadata: { name: '' },
        externalIpId: '',
      }}
      validationSchema={validationSchema(t)}
      onSubmit={async (values) => {
        if (hasNatGateway) {
          return;
        }
        try {
          await createNatGateway.mutateAsync({
            object: {
              metadata: { name: values.metadata.name },
              spec: {
                virtualNetwork: { id: virtualNetwork.id },
                externalIp: { id: values.externalIpId },
              },
            },
          });
          onClose();
        } catch {
          // surfaced via the mutation error state
        }
      }}
    >
      {() => (
        <FieldValidationProvider>
          <PageSection hasBodyWrapper={false}>
            <Stack hasGutter>
              <StackItem>
                <Breadcrumb>
                  <BreadcrumbItem>
                    <Button variant="link" isInline onClick={handleClose}>
                      {t('Virtual networks')}
                    </Button>
                  </BreadcrumbItem>
                  <BreadcrumbItem isActive>{t('NAT gateway attachment')}</BreadcrumbItem>
                </Breadcrumb>
              </StackItem>
              <StackItem>
                <Title headingLevel="h1" size="3xl">
                  {t('NAT gateway attachment')}
                </Title>
              </StackItem>
            </Stack>
          </PageSection>
          <PageSection
            hasBodyWrapper={false}
            isFilled
            type={PageSectionTypes.wizard}
            aria-label={t('NAT gateway attachment wizard')}
          >
            <Wizard
              navAriaLabel={t('NAT gateway attachment steps')}
              isVisitRequired
              footer={
                <OSACWizardFooter
                  onCancel={handleClose}
                  stepHasErrors={attachNatGatewayStepHasErrors}
                  error={createNatGateway.error}
                  isNextDisabled={
                    isLoadingNatGateways ||
                    Boolean(natGatewayError) ||
                    hasNatGateway ||
                    noExternalIpsAvailable ||
                    Boolean(externalIpsError)
                  }
                  submitLabel={t('Create')}
                  errorTitle={t('Failed to create NAT gateway attachment')}
                />
              }
              onStepChange={(_, step) => setCurrentStep(step.id as string)}
            >
              <WizardStep id="nat-gateway" name={t('NAT gateway')}>
                {currentStep === 'nat-gateway' && (
                  <AttachNatGatewayStep
                    virtualNetwork={virtualNetwork}
                    isLoadingExternalIps={isLoadingExternalIps}
                    externalIpsError={externalIpsError}
                    natGatewayError={natGatewayError}
                    noExternalIpsAvailable={noExternalIpsAvailable}
                    hasNatGateway={hasNatGateway}
                    externalIpOptions={externalIpOptions}
                  />
                )}
              </WizardStep>
              <WizardStep id="review" name={t('Review')}>
                {currentStep === 'review' && (
                  <AttachNatGatewayReviewStep
                    virtualNetwork={virtualNetwork}
                    externalIpOptions={externalIpOptions}
                  />
                )}
              </WizardStep>
            </Wizard>
          </PageSection>
        </FieldValidationProvider>
      )}
    </Formik>
  );
};
