# engine/install — установочный оркестратор

Связывает кирпичи надёжности в один поток ([reliability](../../docs/v2/architecture/reliability.md)):

```
preflight → snapshot UCI → шаги по порядку → health-check → commit / rollback
```

## Порядок и почему

`vpn → dns → doh → adblock → wifi → firewall`. VPN (awg0) и DNS-цепочка поднимаются раньше;
**wifi** перед firewall (настройка радио независима от split-routing; no-op без радио/ключа);
**firewall последним** — пометка/ip rule/kill-switch навешиваются поверх уже поднятого awg0 и
готовой DNS-цепочки.

**Пароль root** (`steps/rootpass`) применяется НЕ как шаг реестра, а на **commit-пути** `run.uc`
(после успешных шагов+health): смена пароля — всегда-безопасный runtime-акт, не транзакция; сбой
`passwd` → warning, установка успешна.

## Честный откат (clean vs dirty)

- **Чистые шаги** (vpn/dns/doh/adblock/wifi → uci) откатываются **snapshot restore**.
- **Грязный шаг** (firewall → runtime nft/ip, не uci) при сбое чистится своим **`apply.uc --teardown`**
  (safe-fail), а НЕ иллюзией uci-отката. `snapshot_scope` намеренно не включает firewall.
- Kill-switch усиливает безопасность отката: даже полу-применённый firewall фейлит в туннель.

## Чистое ядро vs импурный run

- **`install.uc`** — `all_steps`/`enabled_steps` (реестр+порядок), `snapshot_scope` (объединение
  чистых uci-конфигов задействованных шагов), `dirty_steps`, `decide_outcome(results)` →
  `abort`/`rollback`/`commit` (fail-safe). **Чистые функции**, тесты — [tests/](tests/).
- **`run.uc`** — **router-side, импурно**: запускает preflight (gather|check), snapshot save,
  каждый шаг (`steps/<name>/apply.uc`), health-check, затем commit (snapshot commit) или rollback
  (snapshot restore + teardown грязных). Откат — функция `rollback_all`, и `run.uc --rollback`
  даёт его как отдельный режим (ubus `install_cancel` зовёт ЕГО, а не копию логики — знание
  «как откатывать» живёт в одном месте). Найдено через `sourcepath` → независимо от пути установки. QEMU.

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

Вход: `{ awg_conf, root_password, ssid, wifi_key, domains, routing_opts{wan_if,...},
disable:[шаги], ... }`. Домены обычно готовит [list](../list/) (user + community); awg_conf,
пароли и SSID приносит пользователь (через ubus-payload 600 — содержит секреты).

## Соседние оркестраторы (router-side, QEMU)

- **`replace_vpn.uc`** — замена AWG-конфига без переустановки: snapshot → vpn-шаг → ждать
  **свежий** handshake (новее старта, до 30 с) → commit / restore (авто-rollback: пользователь
  не остаётся без туннеля). Запускает ubus-метод `replace_awg_conf` (фон+poll).
- **`reset.uc`** — полный teardown cheburnet-конфигурации: firewall `--teardown` (nft/ip +
  NAT-зона), семейный режим off, наши uci-секции (network/dhcp/https-dns-proxy), `/etc/cheburnet`.
  «Что считать нашим» НЕ хардкодит — имена приходят из шагов-владельцев (`vpn.owned_sections`,
  `routing.set_names`, `doh.listen_prefix`, `adblock.addnmount_paths`): переименование в шаге
  подхватывается автоматически. Пакеты, Wi-Fi и пароль root НЕ трогает. Это **не** firstboot
  v1 — сбрасывается cheburnet, не роутер. Идемпотентен. Запускает ubus-метод `factory_reset`.

## Границы

- **health-check** минимальный (DNS резолвится + awg-handshake) — расширяемо.
- Вызов оркестраторов из web — задача **ubus-обработчика**.

## Тесты

`make test-engine`. Покрыто: порядок шагов, enabled/disable, копия реестра, `snapshot_scope`
(дедуп, uci-часть гибридного dirty-шага входит), `dirty_steps`, `decide_outcome`
(abort/rollback/commit, fail-safe).
