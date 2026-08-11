// engine-sync.test.js — сверка продублированных контрактов веб ↔ движок (vitest).
//
// Порядок шагов установки и каталог протоколов существуют в ДВУХ копиях: у движка
// (engine/install/install.uc — источник истины, исполняется на роутере) и у веба
// (STEP_LABELS/installPlan, PROTOCOLS в logic.js — подписи и чеклист). Тесты веба против
// веба сверяют копию с копией; здесь читаем сам файл движка и сверяем с ним — иначе
// перестановка шага в движке заставит чеклист установки молча врать, и ничто не покраснеет.
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { STEP_LABELS, installPlan, protocolList, protocolInfo } from './logic.js';

const engineSrc = readFileSync(
  new URL('../../../engine/install/install.uc', import.meta.url), 'utf8'
);

// Реестр шагов движка: строки вида `{ name: "vpn", ... }` внутри `const STEPS = [...]`.
const stepsBlock = engineSrc.slice(engineSrc.indexOf('const STEPS'), engineSrc.indexOf('];'));
const engineSteps = [...stepsBlock.matchAll(/\{ name: "([a-z0-9-]+)"/g)].map((m) => m[1]);

// Каталог протоколов движка: `awg: { step: "...", ..., conf_key: "awg_conf" }`.
const protoBlock = engineSrc.slice(engineSrc.indexOf('const PROTOCOLS'), engineSrc.indexOf('const DEFAULT_PROTOCOL'));
const engineProtocols = Object.fromEntries(
  [...protoBlock.matchAll(/([a-z0-9]+):\s*\{[^}]*conf_key: "([a-z0-9_]+)"/g)].map((m) => [m[1], m[2]])
);

describe('движок ↔ веб: реестр шагов установки', () => {
  it('парсер нашёл реестр движка (страховка от переименования STEPS)', () => {
    expect(engineSteps.length).toBeGreaterThanOrEqual(5);
    expect(engineSteps).toContain('vpn');
    expect(engineSteps).toContain('firewall');
  });

  it('у каждого шага движка есть подпись STEP_LABELS (иначе чеклист покажет сырой id)', () => {
    for (const s of engineSteps) expect(STEP_LABELS[s], `STEP_LABELS['${s}']`).toBeTruthy();
  });

  // Чеклист = [обвязка run.uc: preflight/singbox-download/snapshot/health-check] + шаги STEPS.
  // Сверяем ПОРЯДОК: подпоследовательность плана, состоящая из шагов STEPS, обязана идти в
  // порядке движка (сам движок исполняет STEPS по порядку реестра).
  it.each([
    ['awg + Wi-Fi', { protocol: 'awg', ssid: 'Home' }, ['singbox']],
    ['awg без Wi-Fi', { protocol: 'awg' }, ['singbox', 'wifi']],
    ['reality + Wi-Fi', { protocol: 'reality', ssid: 'Home' }, ['vpn']],
    ['hysteria2 без Wi-Fi', { protocol: 'hysteria2' }, ['vpn', 'wifi']],
  ])('порядок шагов в плане «%s» совпадает с реестром движка', (_n, args, absent) => {
    const planned = installPlan(args).map((s) => s.id).filter((id) => engineSteps.includes(id));
    expect(planned).toEqual(engineSteps.filter((s) => !absent.includes(s)));
  });
});

describe('движок ↔ веб: каталог протоколов', () => {
  it('наборы протоколов совпадают', () => {
    expect(protocolList().map((p) => p.id).sort()).toEqual(Object.keys(engineProtocols).sort());
  });

  it('conf_key каждого протокола совпадает с движком (иначе install уронит не тот ключ)', () => {
    for (const [id, confKey] of Object.entries(engineProtocols))
      expect(protocolInfo(id).confKey, id).toBe(confKey);
  });
});
