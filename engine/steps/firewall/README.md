# engine/steps/firewall — data-plane: пометка, policy routing, kill-switch

Production-применение split-routing для форвард-трафика LAN-клиентов:

1. **NAT-зона туннеля** — uci firewall: зона `vpn` (awg0, masq + mtu_fix) и forwarding
   `lan→vpn`. Без неё трафик LAN-клиентов уходит в туннель без SNAT/forwarding и не
   возвращается — роутер «зелёный, но не везёт».
2. **Пометка** — наша prerouting-цепочка метит пакеты с `daddr ∈ direct`
   ([policy-routing](../../../docs/v2/concepts/policy-routing.md)).
3. **Policy routing** — `ip rule`/`ip route` разводят помеченное в WAN, остальное в туннель.
4. **Kill-switch** — роняет непрямой трафик, утекающий в WAN мимо туннеля
   ([kill-switch](../../../docs/v2/concepts/kill-switch.md)).

## Kill-switch — ключевые решения (threat model)

> Инвариант v1: kill-switch — **осознанная защита**, не лишний слой. Дырявый kill-switch
> молча обнуляет приватность (всё «работает», но утекает).

- **Ключуемся по `oifname <wan>`, а не по LAN-CIDR.** Это убирает баг v1 (хардкод
  `192.168.1.0/24` → тихо-дырявый kill-switch на нестандартной подсети): правило вообще не
  зависит от подсети LAN.
- **`wan_if` обязателен и динамический** (из gather/preflight). Нет WAN-интерфейса →
  `plan.ok=false`, kill-switch **не строится**, шаг отказывает без изменений. Лучше честный
  отказ, чем хардкод-дыра.
- **`ct state new`** — рубим только новые исходящие соединения мимо туннеля; established
  (обратный трафик уже разрешённого) проходит.
- **AWG-handshake не задет:** он — `output` роутера, а kill-switch на `forward`.
- **TRAVEL строже:** direct-исключений нет → `oifname <wan> ct state new drop` без mark.

## Чистое ядро vs импурный apply

- **`firewall.uc`** — `build_firewall_plan(routing_plan, opts)` → `{uci_teardown, uci_setup,
  nft_teardown, nft_setup, ip_teardown, ip_setup, killswitch, ok, errors}` + `build_nat_ops(opts)`
  (uci-операции NAT-зоны). **Чистые функции**; переиспользует
  `render_sets`/`render_mark_rules`/`render_iprules` из routing (единый источник). Тесты — [tests/](tests/).
- **`apply.uc`** — **router-side, импурно**: NAT-зона (uci batch + commit + fw4 reload) →
  teardown (удалить наши цепочки/правила, `|| true`) → setup (`nft -f -`, `ip`). Проверяется в QEMU.
- **`plan.uc`** — CLI чистого ядра: facts → команды, без применения (локально/в тестах).

> **Порядок критичен:** uci-часть и `fw4 reload` идут **до** nft-инъекции — reload пересобирает
> таблицу `inet fw4` и стёр бы наши цепочки, если бы шёл после них.

## Идемпотентность и откат — честно

Шаг **гибридный**. NAT-зона — uci firewall (именованные секции `cheburnet_vpn`/`cheburnet_lan_vpn`,
delete-before-set): откатывается **чисто** snapshot'ом установки (`firewall ∈ CLEAN_CONFIGS`,
входит в `snapshot_scope`). Состояние ядра (nft/ip) **не откатывается чисто, как UCI**. Поэтому
сходимся **пере-применением** (teardown+setup), а не минимальным diff: на повторе конечное
состояние то же. Свои hooked-цепочки (`cheburnet_mark`, `cheburnet_ks`) удаляются целиком, не
задевая правил fw4; **сеты не удаляем** — в них живут адреса от dnsmasq (удаление = транзиентная
потеря direct-маршрутов). Это прямая реализация «грязный откат не маскируем под транзакцию»
([reliability](../../../docs/v2/architecture/reliability.md)). `--teardown` (standalone-откат
оркестратором) снимает и nft/ip, и NAT-зону.

**Forwarding по имени зоны (`lan→vpn`), не по CIDR** — LAN-подсеть в правилах не фигурирует
(урок v1: хардкод подсети = тихая дыра на нестандартных конфигурациях).

## Использование

```sh
echo '{"domains":["example.com"],"routing_opts":{"ipv6":false,"wan_if":"eth0"}}' \
  | ucode -R engine/steps/firewall/plan.uc          # показать план
echo '{"domains":["example.com"],"routing_opts":{"wan_if":"eth0"}}' \
  | ucode -R engine/steps/firewall/apply.uc --dry-run
```

## Проверка

`make test-engine` (юнит: содержимое kill-switch HOME/TRAVEL, обязательность `wan_if`,
неприкосновенность чужих объектов, ipv6). Сгенерированный `nft_setup` дополнительно
проверен на **реальную загрузку в ядро** через network namespace (`nft -f -`) — правила
синтаксически валидны end-to-end. Полная проверка работы дропа — в QEMU.
