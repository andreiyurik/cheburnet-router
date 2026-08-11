// Контраст темы: парсит токены обеих тем из app.css и проверяет WCAG-минимумы для каждой
// рабочей пары роль×фон. Ломается при любой правке токена, роняющей доступность.
// Откуда взяты сами цвета — docs/kb/architecture/web-theme.md.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';

const css = readFileSync(new URL('./app.css', import.meta.url), 'utf8');

// Токены light — из первого :root, dark — из :root внутри @media (prefers-color-scheme: dark).
function tokens(block) {
  const out = {};
  for (const [, name, hex] of block.matchAll(/--([a-z-]+):\s*(#[0-9a-fA-F]{6})/g)) out[name] = hex;
  return out;
}
const darkAt = css.indexOf('@media (prefers-color-scheme: dark)');
const forcedAt = css.indexOf(':root[data-theme="dark"]');
const light = tokens(css.slice(0, darkAt));
const dark = tokens(css.slice(darkAt, forcedAt));
// Тёмные токены объявлены дважды (системная тема и явный выбор ThemeToggle) — блоки обязаны совпадать.
const darkForced = tokens(css.slice(forcedAt));

const lum = (hex) => {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const ratio = (a, b) => {
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

// [текст, фон, минимум]: 7 — основной текст (AAA), 4.5 — обычный текст (AA), 3 — UI-элементы.
const pairs = [
  ['fg', 'bg', 7],
  ['fg', 'card', 7],
  ['muted', 'card', 4.5],
  ['muted', 'bg', 4.5],
  ['accent', 'card', 4.5], // ссылки, em.req
  ['accent-fg', 'accent', 4.5], // текст primary-кнопки
  ['ok', 'card', 4.5],
  ['bad', 'card', 4.5], // warn-текст, контурная danger-кнопка
  ['bad-fg', 'bad', 4.5], // текст залитой danger-кнопки
  ['attn', 'card', 4.5], // badge-locked, soft-провалы
  ['accent', 'bg', 3], // focus-ring, активная точка степпера
];

it('оба тёмных блока синхронны (media и data-theme)', () => {
  expect(darkForced).toEqual(dark);
});

describe.each([['light', light], ['dark', dark]])('тема %s', (name, t) => {
  it('все токены на месте', () => {
    for (const role of ['bg', 'card', 'fg', 'muted', 'accent', 'accent-fg', 'ok', 'bad', 'bad-fg', 'attn'])
      expect(t[role], `--${role}`).toMatch(/^#/);
  });
  it.each(pairs)('%s на %s ≥ %s:1', (a, b, min) => {
    expect(ratio(t[a], t[b])).toBeGreaterThanOrEqual(min);
  });
});
