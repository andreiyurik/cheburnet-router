// Контраст темы: парсит токены обеих тем из app.css и проверяет WCAG-минимумы для каждой
// рабочей пары роль×фон. Ломается при любой правке токена, роняющей доступность.
// Откуда взяты сами цвета — docs/kb/architecture/web-theme.md.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';

const css = readFileSync(new URL('./app.css', import.meta.url), 'utf8');

// Блок токенов = всё от маркера-селектора до его закрывающей скобки. Искать по маркеру, а не
// по индексу: в файле есть и @custom-variant с тем же media-условием внутри.
function block(marker) {
  const at = css.indexOf(marker);
  if (at < 0) throw new Error(`не найден блок ${marker}`);
  const from = css.indexOf('{', at);
  const to = css.indexOf('}', from);
  return css.slice(from, to);
}
function tokens(text) {
  const out = {};
  for (const [, name, hex] of text.matchAll(/--([a-z-]+):\s*(#[0-9a-fA-F]{6})/g)) out[name] = hex;
  return out;
}

const light = tokens(block(':root {'));
const dark = tokens(block(':root:not([data-theme="light"])'));
// Тёмные токены объявлены дважды (системная тема и явный выбор ThemeToggle) — блоки обязаны совпадать.
const darkForced = tokens(block(':root[data-theme="dark"]'));

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
// muted/secondary — фон подсветки (hover, сегмент, плашка кода): текст на нём тот же, что на карточке.
const pairs = [
  ['foreground', 'background', 7],
  ['foreground', 'card', 7],
  ['foreground', 'muted', 7],
  ['muted-foreground', 'card', 4.5],
  ['muted-foreground', 'background', 4.5],
  ['muted-foreground', 'muted', 4.5],
  ['primary', 'card', 4.5], // ссылки, акцентные подписи
  ['primary', 'muted', 4.5],
  ['primary-foreground', 'primary', 4.5], // текст залитой primary-кнопки
  ['secondary-foreground', 'secondary', 4.5],
  ['success', 'card', 4.5],
  ['destructive', 'card', 4.5], // текст ошибки, контурная danger-кнопка
  ['destructive', 'muted', 4.5],
  ['destructive-foreground', 'destructive', 4.5], // текст залитой danger-кнопки
  ['warning', 'card', 4.5], // бейдж «недоступно», soft-провалы
  ['primary', 'background', 3], // кольцо фокуса, активная точка степпера
];

const ROLES = [
  'background', 'foreground', 'card', 'card-foreground', 'popover', 'popover-foreground',
  'primary', 'primary-foreground', 'secondary', 'secondary-foreground',
  'muted', 'muted-foreground', 'accent', 'accent-foreground',
  'destructive', 'destructive-foreground', 'success', 'warning', 'ring',
];

it('оба тёмных блока синхронны (media и data-theme)', () => {
  expect(darkForced).toEqual(dark);
});

describe.each([['light', light], ['dark', dark]])('тема %s', (name, t) => {
  it('все токены на месте', () => {
    for (const role of ROLES) expect(t[role], `--${role}`).toMatch(/^#/);
  });
  it.each(pairs)('%s на %s ≥ %s:1', (a, b, min) => {
    expect(ratio(t[a], t[b])).toBeGreaterThanOrEqual(min);
  });
});
