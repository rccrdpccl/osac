import { defineConfig } from 'i18next-cli';

export default defineConfig({
  locales: ['en'],
  extract: {
    input: ['../../{libs,apps}/*/src/**/*.{js,jsx,ts,tsx}'],
    output: 'locales/{{language}}/{{namespace}}.json',
    keySeparator: false,
    nsSeparator: '~',
    defaultValue: (key: string) => key,
    removeUnusedKeys: true,
    sort: true,
  },
});
