# engine/install — установочный оркестратор

Связывает кирпичи надёжности в один поток ([reliability](../../docs/kb/architecture/reliability.md)):

```
preflight → snapshot UCI → шаги по порядку → health-check → commit / rollback
```

## Порядок и почему

`vpn → dns → doh → adblock → wifi → firewall`. VPN (awg0) и DNS-цепочка поднимаются раньше;
**wifi** перед firewall (настройка радио независима от split-routing; no-op без радио/ключа);
**firewall последним** — пометка/ip rule/kill-switch навешиваются поверх уже поднятого awg0 и
готовой DNS-цепочки.

**Первая установка — туннель применяется БЕЗ half-routes** (`apply.uc --no-arm`): интерфейс
поднят, health-check может его проверить, но дом ещё не переключён. Half-routes вооружаются
(`apply.uc --arm`) только на commit-пути, после подтверждённого health — см.
[reliability](../../docs/kb/architecture/reliability.md#поверх-всего-fail-safe-направление).
`replace_vpn.uc`/`replace_singbox.uc` это не касается — они всегда вооружают сразу.

**Пароль root** (`steps/rootpass`) применяется НЕ как шаг реестра, а на **commit-пути** `run.uc`
(после успешных шагов+health): смена пароля — всегда-безопасный runtime-акт, не транзакция; сбой
`passwd` → warning, установка успешна.

## Честный откат (clean vs dirty)

- **Чистые шаги** (vpn/dns/doh/wifi → uci) откатываются **snapshot restore**.
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

Вход: `{ protocol, <conf_key>, root_password, ssid, wifi_key, domains, routing_opts{wan_if,...},
disable:[шаги], ... }`, где `protocol` ∈ `awg` | `reality` | `hysteria2`, а конфиг лежит под ключом
этого протокола (`awg_conf` / `reality_conf` / `hysteria2_conf` — соответствие задаёт `PROTOCOLS` в
[install.uc](install.uc), см. `tunnel_conf`). Домены обычно готовит [list](../list/)
(user + community); конфиг туннеля, пароли и SSID приносит пользователь (через ubus-payload 600 —
содержит секреты).

## Соседние оркестраторы (router-side, QEMU)

- **`replace_vpn.uc`** — замена AWG-конфига без переустановки: snapshot → vpn-шаг → ждать
  **свежий** handshake (новее старта, до 30 с) → commit / restore (авто-rollback: пользователь
  не остаётся без туннеля). Запускает ubus-метод `replace_awg_conf` (фон+poll).
- **`replace_singbox.uc`** — то же для Full-тира, ОДИН скрипт на оба протокола (у Reality и
  Hysteria2 общий `config.json`, общий шаг и общая проба): бэкап `config.json` → snapshot →
  singbox-шаг → connectivity-probe через туннель (до 30 с) → commit / restore. `config.json`
  бэкапим руками: uci-снимок внешний файл не покрывает. Запускают методы `replace_reality_conf` /
  `replace_hysteria2_conf`.
- **`install-singbox.sh`** — догрузка бинаря Full-тира (`sing-box-tiny` → `sing-box`, критерий
  успеха = появился бинарь). Зовётся кнопкой `install_full_tier` и самим `run.uc` первым шагом,
  когда выбран Full-протокол, а бинаря нет: до snapshot, поэтому провал = чистый abort.
- **`reapply.uc`** — вернуть runtime-часть data-plane (policy-routing) из сохранённой
  конфигурации. Зовётся hotplug-хуком при подъёме WAN (перезагрузка роутера, реконнект канала) и
  самим `run.uc` при откате поверх рабочей системы — ОДНА реализация на оба случая, иначе
  «после ребута иначе, чем после отката». WAN определяет заново (шлюз мог смениться), на
  ненастроенном роутере молчит. Причина существования — в README шага firewall: nft-часть ребут
  переживает, ip-часть нет.
- **`reset.uc`** — полный teardown cheburnet-конфигурации: firewall `--teardown` (nft/ip +
  NAT-зона), семейный режим off, наши uci-секции (network/dhcp/https-dns-proxy), `/etc/cheburnet`.
  «Что считать нашим» НЕ хардкодит — имена приходят из шагов-владельцев (`vpn.owned_sections`,
  `routing.set_names`, `doh.listen_prefix`, `adblock.addnmount_paths`): переименование в шаге
  подхватывается автоматически. Пакеты, Wi-Fi и пароль root НЕ трогает. Это **не** firstboot
  v1 — сбрасывается cheburnet, не роутер. Идемпотентен. Запускает ubus-метод `factory_reset`.

## Границы

- **health-check** минимальный: DNS резолвится + туннель готов. Чем мерить туннель, решает
  протокол (`uses_singbox`): у AWG — свежий handshake, у Full-тира — connectivity-probe через TUN
  ([probe.uc](probe.uc)). Расширяемо.
- Вызов оркестраторов из web — задача **ubus-обработчика**.

## Тесты

`make test-engine`. Покрыто: порядок шагов, enabled/disable, копия реестра, `snapshot_scope`
(дедуп, uci-часть гибридного dirty-шага входит), `dirty_steps`, `decide_outcome`
(abort/rollback/commit, fail-safe).
