# Split-routing без подкопа на маленьком роутере

Гайд для тех, у кого роутер с **16–32 МБ flash-памяти**: Cudy WR3000 v1 (без P), Xiaomi 4A Gigabit, TP-Link Archer C7, и подобные. Полный cheburnet на таком роутере не помещается, но **рабочий VPN + split-routing по доменам** настроить можно — другим способом.

## Кому это

Установщик cheburnet выдал «РОУТЕР НЕ ПОДХОДИТ: НЕ ХВАТАЕТ FLASH-ПАМЯТИ» или упал на шаге `02-podkop.sh` с сообщением `Insufficient space in flash`. AmneziaWG-туннель при этом у вас, скорее всего, **уже встал** — в логе была строка `✓ awg0 interface UP`.

Покупать новый роутер ($40–55) готов не каждый, особенно если просто хочется попробовать. Этот гайд — альтернативный путь на штатных OpenWrt-пакетах, без подкопа.

## Что не помещается и почему

| Компонент | Размер | Почему такой |
|---|---|---|
| **podkop + sing-box** | ~15 МБ | sing-box — мощный userspace-роутер на Go (статический бинарник, geoip-базы, rule-sets) |
| adblock-lean + блок-лист | ~2 МБ | блок-лист Hagezi Pro распаковывается в `/var/run` |
| wpad-mbedtls (полный, для WPA3 SAE) | ~1 МБ | для шифрования WPA3 |

Не помещается **связка**, в которой подкоп отвечает за split-routing. Сам AmneziaWG-туннель — лёгкий (~2 МБ), на 16 МБ flash он встаёт без проблем.

## Что в итоге работает (этот гайд)

| Фича | Полный cheburnet | На вашем роутере с этим гайдом |
|---|---|---|
| AmneziaWG-туннель | ✅ | ✅ (уже встал на шаге 01) |
| Split-routing по доменам | ✅ через подкоп | ✅ через `dnsmasq-full` + `pbr`, в ядре |
| Subscription rule-sets (тысячи доменов одной подпиской) | ✅ | ❌ — список доменов руками |
| FakeIP (защита от DNS-утечек) | ✅ | ⚠️ слабее: если клиент использует свой DoH, домен пройдёт мимо |
| Авто-обновление списков | ✅ | ❌ — обновляете сами |
| Блокировка рекламы (adblock-lean) | ✅ | ❌ не поместится |
| Killswitch | ✅ | ❌ нет защиты при падении VPN |
| Wi-Fi WPA3 SAE | ✅ | ⚠️ только WPA2 (wpad-mbedtls не поместится) |
| Установочный размер | 30+ МБ | ~0.5–1 МБ (dnsmasq-full + pbr + luci-app-pbr) |

Главный честный минус — **без FakeIP**. Если приложение на устройстве жёстко прописало свой DoH-DNS (например, Chrome с `chrome://flags#dns-over-https`), оно зарезолвит домен в обход dnsmasq → IP не попадёт в split-список → трафик пойдёт мимо VPN. Это не «дыра», это «менее надёжно, чем подкоп». Для бытовых случаев (большинство клиентов идут в DNS роутера) — достаточно.

## Как это работает

```
Клиент → DNS-запрос youtube.com → dnsmasq на роутере
                                     ↓ резолвит, IP добавляет в nftset 'vpn4'
Клиент → пакет на этот IP → nftables
                              ↓ видит IP в 'vpn4', ставит fwmark 0x100
                              ↓
                            ip rule (fwmark 0x100 → таблица 'vpn')
                              ↓
                            default route таблицы 'vpn' = через awg0
                              ↓
                            AmneziaWG → VPN-сервер
```

Никакого userspace-демона — всё в ядре. Это **старый школьный OpenWrt-паттерн**, существовавший до подкопа. `pbr` — это UCI-обёртка ровно над этой механикой.

## Установка (5 шагов)

### 1. Проверить, что AWG-туннель работает

```sh
ip addr show awg0
# Должно быть UP с адресом 100.xx.xx.xx/32

awg show
# Должна быть строка "latest handshake: N seconds ago" — секунды или минуты,
# не "(none)" и не часы
```

Если awg0 не работает — сначала разберитесь с туннелем (см. [docs/02-amneziawg.md](02-amneziawg.md) и [docs/09-troubleshooting.md](09-troubleshooting.md), раздел про handshake). С неработающим туннелем дальнейшие шаги бесполезны.

### 2. Установить пакеты

```sh
apk update
apk add dnsmasq-full pbr luci-app-pbr
```

Если `apk` ругается на конфликт `dnsmasq-full` с обычным `dnsmasq`:

```sh
apk del dnsmasq
apk add dnsmasq-full
```

**UCI-конфиг `/etc/config/dhcp` при этом сохраняется** — все ваши настройки DHCP/DNS остаются на месте. `dnsmasq-full` — это та же dnsmasq, только с включёнными опциями `nftset` и `conntrack` (~200 КБ больше).

### 3. Включить pbr и добавить split-routing policy

```sh
# Включить pbr с резолвером через dnsmasq+nftset (это и даёт домен-роутинг)
uci set pbr.config.enabled='1'
uci set pbr.config.resolver_set='dnsmasq.nftset'
uci set pbr.config.procd_reload_delay='1'

# Policy: эти домены идут через awg0, остальной трафик — напрямую
uci add pbr policy
uci set pbr.@policy[-1].name='via_vpn'
uci set pbr.@policy[-1].interface='awg0'
uci set pbr.@policy[-1].dest_addr='youtube.com googlevideo.com instagram.com x.com twitter.com chatgpt.com openai.com'
uci set pbr.@policy[-1].enabled='1'

uci commit pbr
```

### 4. Запустить

```sh
/etc/init.d/pbr enable
/etc/init.d/pbr start
sleep 3
pbr status
```

`pbr status` должен показать `Status: Enabled` и активные правила.

### 5. Проверить

С устройства в LAN (телефон/ноутбук):

```sh
# Обычный трафик идёт мимо VPN — должен показать ваш провайдерский IP
curl -4 https://api.ipify.org && echo

# Поход на split-домен → должен пройти через VPN
# (открыть в браузере youtube.com и проверить, что страница грузится)

# На роутере: какие IP попали в split-set после визита
nft list set inet fw4 vpn4 2>/dev/null | head -20
# Должны быть IP'шники YouTube/Google после посещения youtube.com
```

Если в `nft list set` пусто после визита на YouTube — клиент использует не dnsmasq роутера, а свой DNS. Проверьте на телефоне: настройки Wi-Fi → IP → DNS-серверы должны быть пустыми или указывать на роутер (`192.168.1.1`).

## Расширение списка доменов

Базовый список из 7 доменов — для проверки что схема работает. Дальше расширяйте под себя.

**Откуда брать домены:**
- [community-lists подкопа](https://github.com/itdoginfo/podkop/tree/main/lists) — готовые списки заблокированных сервисов, можно скопировать любой `.lst` и адаптировать.
- Свои добавления — какие сайты лично у вас не открываются.

**Длинный список — лучше файлом:**

```sh
# Положить домены по одному на строку
cat > /etc/pbr/vpn-domains.txt <<'EOF'
youtube.com
googlevideo.com
instagram.com
x.com
twitter.com
chatgpt.com
openai.com
# ... ваши добавления
EOF

# Сказать pbr читать из файла. ВАЖНО: использовать тот же индекс [-1],
# которым добавили policy выше (или name-based reference). [0] здесь
# был бы неверен, если у вас в pbr есть другие policy кроме нашей.
uci -q delete pbr.@policy[-1].dest_addr
uci set pbr.@policy[-1].dest_addr_file='/etc/pbr/vpn-domains.txt'
uci commit pbr
/etc/init.d/pbr restart
```

## Если что-то не работает

**Все домены продолжают резолвиться напрямую (трафик не идёт через VPN):**
- Проверьте, что клиент использует роутер как DNS: с клиента `nslookup youtube.com 192.168.1.1` должно идти к dnsmasq роутера, не к `8.8.8.8` в обход.
- На Android/iOS отключите «приватный DNS» (DoH/DoT) — он перехватывает запросы у dnsmasq.
- В Chrome отключите Secure DNS (`chrome://settings/security`).

**nftset `vpn4` пустой после визита на YouTube:**
- Проверьте что dnsmasq именно **dnsmasq-full**: `apk list --installed | grep dnsmasq` должно показать `dnsmasq-full`, не `dnsmasq-basic`.
- Проверьте что `pbr.config.resolver_set='dnsmasq.nftset'`: `uci get pbr.config.resolver_set`.
- Перезапустите оба: `/etc/init.d/dnsmasq restart && /etc/init.d/pbr restart`.

**AWG-туннель отваливается раз в N минут:**
- Это не про pbr. См. [docs/02-amneziawg.md](02-amneziawg.md) и [docs/09-troubleshooting.md](09-troubleshooting.md).

**Не помогло, всё равно не работает:**
- Напишите в Telegram: [@industrialprofi](https://t.me/industrialprofi).
- Приложите `pbr status`, `uci show pbr`, `nft list ruleset | head -80`, и описание клиента (Android/iOS/Windows, какой DNS прописан).

## Альтернативы

Если этот путь не подойдёт или захочется полный cheburnet — есть два варианта.

### A. Middlebox-топология (не выкидывая текущий роутер)

Купить дешёвый cheburnet-совместимый роутер ($40–55, [Cudy TR3000](https://www.cudy.com/products/tr3000) подходит идеально) и поставить его **перед** текущим:

```
Интернет → [новый_cheburnet_роутер] → [ваш_текущий_роутер] → устройства
```

Текущий роутер ничего не меняет — продолжает раздавать Wi-Fi и DHCP как раздаёт. Новый делает всю работу cheburnet'а (VPN, split-routing, adblock, killswitch). Старый роутер не выбрасываем. Wi-Fi-сеть для домашних устройств остаётся та же, переезд незаметен.

### B. VPN на клиентах (без роутера)

Поставить [AmneziaVPN](https://amnezia.org) на телефон/ноутбук напрямую. Это не cheburnet — split-routing на роутерном уровне не получите — но если нужен просто VPN-канал, это нулевой риск для домашней сети.

## Честно про этот документ

Этот гайд написан на основе стандартных OpenWrt-паттернов (`dnsmasq+nftset+pbr` — то, как делали split-routing до появления подкопа). Я **не часть cheburnet** — это сторонние пакеты, у меня нет тестовой лаборатории с 16 МБ-роутерами, и я не могу гарантировать что у вас всё взлетит без правок.

Если что-то не сработает — напишите в Telegram ([@industrialprofi](https://t.me/industrialprofi)), разберёмся вместе, и я уточню документ для следующих людей с такими же роутерами. Чем больше живых кейсов — тем точнее гайд.

Полная установка cheburnet поддерживается только на роутерах из [списка совместимого железа](../README.md#совместимое-железо).
