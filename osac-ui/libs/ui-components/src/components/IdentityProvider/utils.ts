import { IdentityProvider } from '@osac/types';

export const getIdpName = (idp: IdentityProvider) =>
  idp.spec?.title || idp.metadata?.name || idp.id;
