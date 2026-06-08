# engine/install — установочный оркестратор

Связывает кирпичи надёжности в один поток ([reliability](../../docs/v2/architecture/reliability.md)):

```
preflight → snapshot UCI → шаги по порядку → health-check → commit / rollback
```

## Порядок и почему

`vpn → dns → doh → adblock → firewall`. VPN (awg0) и DNS-цепочка поднимаются раньше; **firewall
последним** — пометка/ip rule/kill-switch навешиваются поверх уже поднятого awg0 и готовой
DNS-цепочки.

## Честный откат (clean vs dirty)

- **Чистые шаги** (vpn/dns/doh/adblock → uci) откатываются **snapshot restore**.
- **Грязный шаг** (firewall → runtime nft/ip, не uci) при сбое чистится своим **`apply.uc --teardown`**
  (safe-fail), а НЕ иллюзией uci-отката. `snapshot_scope` намеренно не включает firewall.
- Kill-switch усиливает безопасность отката: даже полу-применённый firewall фейлит в туннель.

## Чистое ядро vs импурный run

- **`install.uc`** — `all_steps`/`enabled_steps` (реестр+порядок), `snapshot_scope` (объединение
  чистых uci-конфигов задействованных шагов), `dirty_steps`, `decide_outcome(results)` →
  `abort`/`rollback`/`commit` (fail-safe). **Чистые функции**, тесты — [tests/](tests/).
- **`run.uc`** — **router-side, импурно**: запускает preflight (gather|check), snapshot save,
  каждый шаг (`steps/<name>/apply.uc`), health-check, затем commit (snapshot commit) или rollback
  (snapshot restore + teardown грязных). Найдено через `sourcepath` → независимо от пути установки. QEMU.

## decide_outcome — порядок проверок (fail-safe)

1. preflight не ok → **abort** (ничего не трогали);
2. любой шаг упал → **rollback** (+ список failed);
3. health-check не ok → **rollback**;
4. всё ок → **commit**.

## Использование

```sh
echo '{"awg_conf":"<...>","domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}' \
  | ucode -R engine/install/run.uc
ucode -R engine/install/run.uc --dry-run < install.json   # показать план без изменений
```

Вход: `{ awg_conf, domains, routing_opts{wan_if,...}, disable:[шаги], ... }`. Домены обычно
готовит [list](../list/) (user + community); awg_conf приносит пользователь.

## Границы

- **health-check** минимальный (DNS резолвится + awg-handshake) — расширяемо.
- Вызов оркестратора из web — задача **ubus-обработчика** (следующая фаза).
- NAT-зона awg0 (masq, forwarding lan→vpn) пока вне firewall-шага — отдельная доработка.

## Тесты

`make test-engine`. Покрыто: порядок шагов, enabled/disable, копия реестра, `snapshot_scope`
(дедуп, исключение dirty), `dirty_steps`, `decide_outcome` (abort/rollback/commit, fail-safe).
