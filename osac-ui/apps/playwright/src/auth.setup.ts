import { expect, test as setup } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

import { AUTH_FILE } from './auth-file';

setup('authenticate', async ({ page }) => {
  const username = process.env.OSAC_USERNAME;
  const password = process.env.OSAC_PASSWORD;
  if (!username || !password) {
    throw new Error('OSAC_USERNAME and OSAC_PASSWORD must be set to a valid Keycloak test user.');
  }

  // The app checks /api/login/info on load and, if unauthenticated, immediately
  // redirects the browser to Keycloak itself (apps/app-frontend/src/hooks/oidc-login.tsx)
  // — there is no login button to click first. This realm's theme is a two-step
  // identifier-first flow: username + "Sign In" submits to a second screen.
  // Field/button names match Keycloak's default theme; a custom theme may differ.
  await page.goto('/');
  await page.getByLabel('Username or email').fill(username);
  await page.getByRole('button', { name: 'Sign In' }).click();

  // The first Keycloak brokers to a second Keycloak (identity provider), which
  // presents its own login screen. That screen may show the username field
  // again — re-enter the username there before the password. On a plain
  // single-Keycloak two-step flow this field simply never reappears and we
  // fall straight through to the password step.
  const usernameField = page.getByLabel('Username or email');
  const passwordField = page.locator('input[type="password"]');
  await Promise.race([
    usernameField.waitFor({ state: 'visible' }).catch(() => {}),
    passwordField.waitFor({ state: 'visible' }).catch(() => {}),
  ]);
  if (await usernameField.isVisible().catch(() => false)) {
    await usernameField.fill(username);
    // If the second screen is identifier-first too (no password field yet),
    // submit to advance to its password step.
    if (!(await passwordField.isVisible().catch(() => false))) {
      await page.getByRole('button', { name: 'Sign In' }).click();
      await passwordField.waitFor({ state: 'visible' });
    }
  }

  // getByLabel('Password') is ambiguous — it also matches the theme's "Show
  // password" toggle button, which shares the same label association. A
  // native input[type=password] has no ARIA role, so getByRole('textbox')
  // won't match it either.
  await passwordField.fill(password);
  await page.getByRole('button', { name: 'Sign In' }).click();

  await expect(page.getByRole('button', { name: 'Account menu' })).toBeVisible();

  // Harden the .auth directory before storageState writes into it — AUTH_FILE
  // holds a live, real Keycloak session cookie, and creating the dir with
  // default permissions first would briefly expose it before the chmod below.
  fs.mkdirSync(path.dirname(AUTH_FILE), { recursive: true, mode: 0o700 });
  await page.context().storageState({ path: AUTH_FILE });
  // Restrict to the current user so other local accounts on a shared machine
  // can't reuse the session; also re-assert dir perms in case it pre-existed
  // with looser permissions.
  fs.chmodSync(path.dirname(AUTH_FILE), 0o700);
  fs.chmodSync(AUTH_FILE, 0o600);
});
