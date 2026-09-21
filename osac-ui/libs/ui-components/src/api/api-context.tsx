import { createContext, useContext, useMemo } from 'react';
import type { DescService } from '@bufbuild/protobuf';
import {
  type Client,
  Code,
  ConnectError,
  type Interceptor,
  type Transport,
  createClient,
} from '@connectrpc/connect';

import { UnauthorizedError } from '../utils/unauthorizedError';

export const connectErrorInterceptor: Interceptor = (next) => async (req) => {
  try {
    return await next(req);
  } catch (err) {
    if (err instanceof ConnectError && err.code === Code.Unauthenticated) {
      throw new UnauthorizedError();
    }
    throw err;
  }
};

type ApiContextValue = { transport: Transport };

const ApiContext = createContext<ApiContextValue | null>(null);

interface ApiProviderProps {
  transport: Transport;
  children: React.ReactNode;
}

export const ApiProvider = ({ transport, children }: ApiProviderProps) => (
  <ApiContext.Provider value={{ transport }}>{children}</ApiContext.Provider>
);

export const useApiFetch = <T extends DescService>(service: T): Client<T> => {
  const ctx = useContext(ApiContext);
  if (!ctx) {
    throw new Error('useApiFetch must be called inside <ApiProvider>');
  }
  return useMemo(() => createClient(service, ctx.transport), [service, ctx.transport]);
};
