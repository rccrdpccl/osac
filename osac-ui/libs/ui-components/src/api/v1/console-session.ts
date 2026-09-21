import { type MessageInitShape } from '@bufbuild/protobuf';
import { useMutation } from '@tanstack/react-query';

import { ConsoleSessionSchema, ConsoleSessions } from '@osac/types';

import { useTranslation } from '../../hooks/useTranslation';
import { useApiFetch } from '../api-context';

export const useCreateConsoleSession = () => {
  const { t } = useTranslation();
  const client = useApiFetch(ConsoleSessions);
  return useMutation({
    mutationFn: async (session: MessageInitShape<typeof ConsoleSessionSchema>) => {
      const response = await client.create({ object: session });
      if (!response.object) {
        throw new Error(t('Console session was not returned'));
      }
      return response.object;
    },
  });
};
