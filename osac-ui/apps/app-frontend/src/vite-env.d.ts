/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** OSAC_WORKAROUND_REMOVE(vite-dev-bearer): dev-only; remove when OIDC supplies tokens. */
  readonly VITE_DEV_BEARER_TOKEN?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
