// Apply PatternFly theme/contrast before React boots to avoid a flash of the wrong theme.
(function () {
  const html = document.documentElement;
  // Felt brand tokens — always on
  html.classList.add('pf-v6-theme-felt');

  let theme = localStorage.getItem('osac/theme') || 'system';
  if (theme === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches) {
    theme = 'dark';
  }
  html.classList.toggle('pf-v6-theme-dark', theme === 'dark');

  let contrast = localStorage.getItem('osac/contrast') || 'system';
  if (contrast === 'system') {
    contrast = window.matchMedia('(prefers-contrast: more)').matches ? 'contrast' : 'glass';
  }
  html.classList.toggle('pf-v6-theme-high-contrast', contrast === 'contrast');
  html.classList.toggle('pf-v6-theme-glass', contrast === 'glass');
})();
