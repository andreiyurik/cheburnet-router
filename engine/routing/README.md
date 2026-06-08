# engine/routing — генератор конфигов split-routing

Превращает **список доменов прямого доступа** в три артефакта data-plane. Чистая логика на
ucode: на вход — домены и опции, на выход — строки конфигов и команды. Ни роутера, ни
сети при генерации не нужно → юнит-тестируется за секунды.

> Концепции, на которых стоит модуль: [split-routing](../../docs/v2/concepts/split-routing.md),
> [dnsmasq-nftset](../../docs/v2/concepts/dnsmasq-nftset.md),
> [policy-routing](../../docs/v2/concepts/policy-routing.md).

## Что генерируется

```
        домены прямого доступа                  opts (mark, table, set, wan, mode, hook)
                  │                                          │
                  ▼                                          ▼
            ┌───────────────────────── build_plan() ─────────────────────────┐
            │  нормализация · валидация (LDH/punycode) · дедуп · отбрасывание  │
            │  мусора в rejected (fail-safe)                                   │
            └───────┬──────────────────────┬──────────────────────┬───────────┘
                    ▼                       ▼                      ▼
            render_dnsmasq()         render_nft()          render_iprules()
       /example.com/4#inet#       add set … direct       ip rule add fwmark
       fw4#direct                 add rule … @direct      0x1 lookup 100
       (dnsmasq кладёт IP          meta mark set 0x1      ip route add default
        в set на резолве)         (ядро метит пакет)       … table 100 (прямой путь)
```

**Ключевой инсайт:** доменно-зависим только слой dnsmasq. Правила nft и `ip rule` —
функция от опций, а не от списка: ядро работает с сетом по ссылке (`@direct`), а наполняет
его dnsmasq на лету. Поэтому список из 10 или 10 000 доменов даёт одни и те же 4 строки nft.

## Формат dnsmasq nftset

`/<домен>/<семейство>#<nft-family>#<fw-table>#<имя-set>` — например
`/example.com/4#inet#fw4#direct`. Семейство `4`/`6` → IPv4/IPv6; OpenWrt держит таблицу в
`inet fw4`. Не-ASCII домены (IDN) валидны только в форме punycode (`xn--…`) — юникод
отбрасывается, иначе он бы не сматчился в DNS.

## Fail-safe при генерации

Невалидный домен **не роняет** генерацию — он уходит в `plan.rejected` и просто не попадает
в direct-список. Промах = трафик на этот домен идёт через туннель (безопасно), а не утекает.
`rejected` отдаётся наверх, чтобы движок честно показал пользователю, что отбросил.

## Режимы и hook

- **mode** `home` (split) / `travel` (full tunnel: dnsmasq и ip rule пусты, остаются только
  объявления сетов) — см. [home-travel-modes](../../docs/v2/concepts/home-travel-modes.md).
- **hook** `prerouting` (по умолчанию — форвард-трафик LAN-клиентов на роутере) /
  `output` (локально-сгенерированный трафик). `output` нужен для прогона в network namespace,
  где пакеты рождаются локально и не проходят prerouting — это путь e2e-теста, не прод.

## Использование

```sh
# JSON-запрос (контракт движка/ubus): what ∈ all|dnsmasq|dnsmasq_uci|nft|iprules
echo '{"what":"nft","domains":["example.com"],"opts":{"ipv6":false}}' \
  | ucode -R engine/routing/generate.uc

# Простые строки-домены ('#' — комментарий, inline-комментарии отсекаются):
printf 'example.com\nexample.org\n' | ucode -R engine/routing/generate.uc
```

Применение, идемпотентность (delete-before-add) и резолв WAN — **не здесь**, а в `engine/steps`.
Этот модуль только генерирует текст.

## Тесты

Юнит — [tests/](tests/) (`make test-engine`). End-to-end через network namespace, где
**реальный вывод генератора** разводит трафик, — [tests/poc/split-routing-netns.sh](../../tests/poc/split-routing-netns.sh)
(`make poc-split`), фаза B.
