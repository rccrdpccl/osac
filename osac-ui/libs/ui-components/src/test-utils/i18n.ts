import { initReactI18next } from 'react-i18next';
import i18n from 'i18next';
import type { TFunction } from 'i18next';

import en from '../../../i18n/locales/en/translation.json';

export const tIdentity = ((key: string) => key) as TFunction;

export const initTestI18n = async () => {
  const instance = i18n.createInstance();
  await instance.use(initReactI18next).init({
    lng: 'en',
    fallbackLng: 'en',
    resources: { en: { translation: en } },
    interpolation: { escapeValue: false },
  });
  return instance;
};
