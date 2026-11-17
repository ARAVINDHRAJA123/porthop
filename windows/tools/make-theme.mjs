// Writes renderer/theme.css: the Material 3 Expressive design tokens PortHop for Windows uses.
//  - colour roles from Google's Material colour library (Expressive scheme, 2025 colour spec), dark theme,
//    generated from PortHop's blue, plus success and warning colours harmonised with it;
//  - spring motion curves (Material's expressive motion uses springs; CSS gets them as linear() easings);
//  - a small library of expressive shapes as polygons with the same number of points, so they can morph.
// Run: node --import ./tools/js-extension-hook.mjs tools/make-theme.mjs
import fs from 'node:fs';
import { argbFromHex, hexFromArgb, Hct, SchemeExpressive, Blend } from '@material/material-color-utilities';

const SEED = '#3d8bff';
const roles = ['primary', 'onPrimary', 'primaryContainer', 'onPrimaryContainer', 'secondary', 'onSecondary', 'secondaryContainer',
  'onSecondaryContainer', 'tertiary', 'onTertiary', 'tertiaryContainer', 'onTertiaryContainer', 'error', 'onError', 'errorContainer',
  'onErrorContainer', 'surface', 'surfaceDim', 'surfaceBright', 'surfaceContainerLowest', 'surfaceContainerLow', 'surfaceContainer',
  'surfaceContainerHigh', 'surfaceContainerHighest', 'onSurface', 'onSurfaceVariant', 'outline', 'outlineVariant', 'inverseSurface',
  'inverseOnSurface', 'inversePrimary', 'scrim', 'shadow', 'primaryFixedDim', 'onPrimaryFixed', 'secondaryFixedDim', 'onSecondaryFixed',
  'tertiaryFixedDim', 'onTertiaryFixed'];
const kebab = (s) => s.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase());

// The colour roles for one mode, as CSS custom properties.
function colours(dark) {
  const scheme = new SchemeExpressive(Hct.fromInt(argbFromHex(SEED)), dark, 0, '2025');
  const out = [];
  for (const r of roles) {
    const v = scheme[r];
    if (typeof v === 'number') out.push(`  --md-${kebab(r)}: ${hexFromArgb(v)};`);
  }
  // The 2025 spec's dark secondary container sits almost on the surface tone, so tonal buttons and progress tracks
  // looked disabled. In dark mode, lift it to tone 30 with tone 90 on top, as in the 2021 spec.
  if (dark) {
    const lift = { 'secondary-container': scheme.secondaryPalette.tone(30), 'on-secondary-container': scheme.secondaryPalette.tone(90) };
    for (let i = 0; i < out.length; i++) {
      const m = out[i].match(/^  --md-([a-z-]+):/);
      if (m && lift[m[1]] !== undefined) out[i] = `  --md-${m[1]}: ${hexFromArgb(lift[m[1]])};`;
    }
  }
  // Success and warning are not Material roles; harmonise them with the seed and take this mode's tones.
  for (const [name, hex] of [['success', '#3ccb7f'], ['warning', '#ffb547']]) {
    const h = Hct.fromInt(Blend.harmonize(argbFromHex(hex), argbFromHex(SEED)));
    const tone = (t) => hexFromArgb(Hct.from(h.hue, h.chroma, t).toInt());
    const [a, on, c, onC] = dark ? [80, 20, 30, 90] : [40, 100, 90, 10];
    out.push(`  --md-${name}: ${tone(a)};`, `  --md-on-${name}: ${tone(on)};`, `  --md-${name}-container: ${tone(c)};`, `  --md-on-${name}-container: ${tone(onC)};`);
  }
  out.push(`  color-scheme: ${dark ? 'dark' : 'light'};`);
  return out;
}
const lightColours = colours(false), darkColours = colours(true);
const lines = [];

// Springs: simulate a unit spring and sample it into a CSS linear() easing.
function spring(name, damping, stiffness) {
  const w0 = Math.sqrt(stiffness), dt = 1 / 1000;
  const x = (t) => {
    if (damping < 1) {
      const wd = w0 * Math.sqrt(1 - damping * damping);
      return 1 - Math.exp(-damping * w0 * t) * (Math.cos(wd * t) + (damping * w0 / wd) * Math.sin(wd * t));
    }
    return 1 - Math.exp(-w0 * t) * (1 + w0 * t);
  };
  let T = 0.05;
  for (let t = 0; t < 3; t += dt) { if (Math.abs(1 - x(t)) > 0.002) T = t; }
  const pts = [];
  for (let i = 0; i <= 40; i++) pts.push(+x((T * i) / 40).toFixed(4));
  pts[40] = 1;
  lines.push(`  --md-spring-${name}: linear(${pts.join(', ')});`, `  --md-spring-${name}-ms: ${Math.round(T * 1000)}ms;`);
}
spring('fast-spatial', 0.6, 1400);     // quick, with a little bounce: presses, chips, small movements
spring('default-spatial', 0.8, 380);   // screen elements moving and changing shape
spring('effects', 1, 1600);            // colour and opacity: no overshoot

// Shapes: radius as a function of angle, sampled at the same 72 points so any two can morph into each other.
const N = 72;
const shapes = {
  circle: () => 1,
  cookie9: (a) => 1 - 0.07 * (1 - Math.cos(9 * a)),
  cookie4: (a) => 1 - 0.11 * (1 - Math.cos(4 * a)),
  cookie6: (a) => 1 - 0.09 * (1 - Math.cos(6 * a)),
  clover4: (a) => 0.66 + 0.34 * Math.pow(Math.abs(Math.cos(2 * a)), 0.55),
  flower: (a) => 0.72 + 0.28 * Math.pow(Math.abs(Math.cos(3 * a)), 0.7),
  sunny: (a) => 1 - 0.09 * (1 - Math.cos(8 * a)) - 0.04 * (1 - Math.cos(16 * a)),
  burst: (a) => 0.78 + 0.22 * Math.pow(Math.abs(Math.cos(6 * a)), 2.5),
  squircle: (a) => Math.pow(Math.pow(Math.abs(Math.cos(a)), 4.5) + Math.pow(Math.abs(Math.sin(a)), 4.5), -1 / 4.5),
};
for (const [name, r] of Object.entries(shapes)) {
  const raw = [];
  for (let i = 0; i < N; i++) { const a = (2 * Math.PI * i) / N; raw.push(r(a)); }
  const max = Math.max(...raw);
  const pts = raw.map((v, i) => {
    const a = (2 * Math.PI * i) / N - Math.PI / 2, rr = v / max;
    return `${(50 + 50 * rr * Math.cos(a)).toFixed(2)}% ${(50 + 50 * rr * Math.sin(a)).toFixed(2)}%`;
  });
  lines.push(`  --md-shape-${name}: polygon(${pts.join(', ')});`);
}

const css = `/* Generated by tools/make-theme.mjs (Material 3 Expressive tokens for PortHop). Do not edit by hand. */
/* Light by default, dark when the system is dark; data-theme on <html> overrides the system (the app's Appearance setting). */
:root {
${lines.join('\n')}
${lightColours.join('\n')}
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
${darkColours.map((l) => '  ' + l).join('\n')}
  }
}
:root[data-theme="dark"] {
${darkColours.join('\n')}
}
${Object.keys(shapes).map((n) => `.shape-${n} { clip-path: var(--md-shape-${n}); }`).join('\n')}
@keyframes md-loading {
  0% { clip-path: var(--md-shape-cookie9); transform: rotate(0deg); }
  20% { clip-path: var(--md-shape-clover4); }
  40% { clip-path: var(--md-shape-sunny); }
  60% { clip-path: var(--md-shape-squircle); }
  80% { clip-path: var(--md-shape-flower); }
  100% { clip-path: var(--md-shape-cookie9); transform: rotate(360deg); }
}
`;
fs.writeFileSync(new URL('../renderer/theme.css', import.meta.url), css);
console.log('theme.css:', lightColours.length, 'light and', darkColours.length, 'dark tokens,', Object.keys(shapes).length, 'shapes');
