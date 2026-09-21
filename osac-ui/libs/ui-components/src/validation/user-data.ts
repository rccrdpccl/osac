import { TFunction } from 'i18next';
import * as Yup from 'yup';

const USER_DATA_MAX_BYTES = 65536;

export const userDataSchema = (t: TFunction) =>
  Yup.string().test('user-data-max-bytes', t('User data must not exceed 64 KB.'), (value) => {
    if (!value) {
      return true;
    }
    return new TextEncoder().encode(value).byteLength <= USER_DATA_MAX_BYTES;
  });
