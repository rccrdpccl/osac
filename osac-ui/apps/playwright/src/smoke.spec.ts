import { expect, test } from '@playwright/test';

test('authenticated app loads and shows the masthead', async ({ page }) => {
  await page.goto('/');

  await expect(page.getByRole('banner')).toBeVisible();
});
