# 📋 Справочник команд — шпаргалка на одной странице

Все CLI-команды в одном месте. Для деталей — ссылки на соответствующие главы.

**Все команды запускаются с вашего ноутбука через SSH:**
```bash
ssh root@192.168.1.1 <команда>
```

Или сначала залогиньтесь, потом команды без `ssh`:
```bash
ssh root@192.168.1.1
# теперь вы на роутере
vpn-mode status
```

---

## 🎯 Самое частое

```bash
# Статус VPN + DNS + режим
vpn-mode status
dns-provider status
awg show awg0 | grep handshake

# Последние события системы
logread | tail -50

# Нашли проблему — универсальный перезапуск
/etc/init.d/podkop restart
```

---

## 🧭 Переключение режимов HOME / TRAVEL

См. [docs/07-modes.md](07-modes.md)

```bash
vpn-mode home          # HOME: split-routing (VPN для всего кроме .ru/vk/etc)
vpn-mode travel        # TRAVEL: full tunnel, всё через VPN
vpn-mode toggle        # Переключить на противоположный
vpn-mode status        # Показать текущее
vpn-mode detect        # Синхронизировать по GPIO-слайдеру (только Beryl AX)
```

**Физическая кнопка** (Cudy TR3000, Beryl AX) — переключает режим нажатием автоматически.  
На других роутерах — только CLI.

---

## 🔒 DNS (Quad9 / Cloudflare)

См. [docs/05-dns.md](05-dns.md)

```bash
dns-provider status        # Какой DNS сейчас активен
dns-provider quad9         # Переключить на Quad9 (default)
dns-provider cloudflare    # Переключить на Cloudflare

# Автофейловер крутится в cron, вручную не трогаем
logread -t dns-health      # История автофейловера
```

---

## 📊 Замеры скорости и качества сети

См. [scripts/net-benchmark](../scripts/net-benchmark)

```bash
net-benchmark                  # Полный тест (~60 сек):
                               #   download + bufferbloat grade A+...F
                               #   рекомендация SQM

net-benchmark quick            # Только скорость (~20 сек, без bufferbloat)

# После теста — применить рекомендованный SQM:
sqm-tune 76 76                 # 76 download Mbps, 76 upload Mbps (95% margin)
```

Подробно про SQM — [docs/10-upgrades.md](10-upgrades.md).

---

## 💾 NAS (Samba-шара через USB-диск)

```bash
# Смонтирован ли USB-диск
df -h /mnt/storage
ls /mnt/storage

# Безопасно извлечь диск (перед unplug)
umount /mnt/storage

# SMB-credentials (user/pass)
cat /root/family-smb.txt

# Статус ksmbd
/etc/init.d/ksmbd status
ps | grep ksmbd
```

Подключение с клиентов:
- **Windows:** `\\192.168.1.1\storage` в Проводнике
- **macOS:** Finder → Go → Connect → `smb://192.168.1.1/storage`
- **Linux:** `smbclient //192.168.1.1/storage -U family`

---

## 🛡 AmneziaWG (VPN)

См. [docs/02-amneziawg.md](02-amneziawg.md)

```bash
# Состояние туннеля
awg show awg0                          # Полный статус
awg show awg0 | grep handshake         # Когда последний handshake
awg show awg0 | grep transfer          # Сколько передано

# Ручной перезапуск (watchdog делает это автоматом при протухшем handshake)
ifdown awg0 && ifup awg0

# Логи watchdog'а
logread -t awg-watchdog
cat /tmp/awg-watchdog/fails            # Счётчик подряд-неудач
```

---

## 🚫 Adblock

См. [docs/04-adblock.md](04-adblock.md)

```bash
# Статус adblock-lean
/etc/init.d/adblock-lean status

# Сколько доменов в блок-листе
zcat /var/run/adblock-lean/abl-blocklist.gz | tr '/' '\n' | grep -c '\.'

# Тест: блокируется ли конкретный домен?
nslookup doubleclick.net 192.168.1.1   # пустой ответ = BLOCKED

# Обновить блок-лист сейчас (cron делает раз в сутки)
/etc/init.d/adblock-lean start

# Добавить/убрать свои домены
vim /etc/adblock-lean/allowlist        # разблокировать
vim /etc/adblock-lean/blocklist        # заблокировать дополнительно
/etc/init.d/adblock-lean start         # применить

# Семейный фильтр (Hagezi NSFW, ~95 600 доменов взрослого контента)
. /opt/cheburnet/lib/family-filter.sh && family_filter_status   # true | false
. /opt/cheburnet/lib/family-filter.sh && family_filter_on       # включить
. /opt/cheburnet/lib/family-filter.sh && family_filter_off      # выключить
```

---

## 🚦 SQM (CAKE — борьба с bufferbloat)

```bash
# Статус
tc -s qdisc show dev eth0 | head

# Применить новые значения (Mbps → автоматически 95%)
sqm-tune 76 76                         # 76/76 Mbps

# Отключить
uci set sqm.eth0.enabled='0'
uci commit sqm
/etc/init.d/sqm stop
```

---

## 📡 Wi-Fi

См. [docs/06-wifi.md](06-wifi.md)

```bash
# Подключённые клиенты (их сила сигнала, скорость, MAC)
iw dev phy1-ap0 station dump           # 5 ГГц
iw dev phy0-ap0 station dump           # 2.4 ГГц

# Сменить SSID/пароль
uci set wireless.default_radio0.ssid='NewName'
uci set wireless.default_radio0.key='newpassword'
# то же для default_radio1
uci commit wireless
wifi reload
```

---

## 📋 Логи (что где смотреть)

> **Полный гайд** с типовыми сценариями отладки, live-state файлами и инструкцией «что прислать в саппорт» — в [09-troubleshooting.md → Логи](09-troubleshooting.md#логи--куда-смотреть).

```bash
# Всё в real-time
logread -f

# По конкретным компонентам (наши `logger -t`-метки)
logread -e vpn-mode                    # Переключения режимов
logread -e dns-health                  # Автофейловер DNS (только при сбое)
logread -e dns-provider                # Ручные свитчи DNS
logread -e awg-watchdog                # Перезапуски AWG (только при handshake>180с)
logread -e conntrack-monitor           # Conntrack ≥80% (норма = молчит)
logread -e adblock-lean                # Загрузка блок-листа
logread -e podkop                      # Podkop events
logread -e podkop-weekly               # Еженедельный перезапуск sing-box (пн 4:00 MSK)
logread | grep sing-box                # Sing-box (большой объём)

# Live-state (что прямо сейчас, без логов)
awg show awg0 | grep handshake             # Свежесть VPN-туннеля
cat /tmp/awg-watchdog/fails                # Подряд-рестартов awg0 (>3 = проблема)
cat /tmp/dns-health/fails                  # DNS пробинг фейлится сейчас?
cat /proc/sys/net/netfilter/nf_conntrack_count  # Заполненность conntrack

# Персистентные логи (14 дней на flash, снапшот в 23:55)
ls /root/logs/
cat /root/logs/system-2026-04-17.log

# Ручной снапшот текущих логов
/usr/bin/log-snapshot

# Логи установки (только если был сбой setup.sh / веб-мастера)
cat /tmp/cheburnet/install.log
cat /tmp/cheburnet/done                 # "ok" или "fail-NN-stepname"
```

> **Если `logread -e <tag>` пустой — это норма.** Cron-задачи логируют **только** аномалии (рефакторинг 2026-05). До этого они писали «OK …» каждый запуск, давая 1800+ строк/день шума.

---

## ⚙️ Системное администрирование

```bash
# Общее состояние
uptime                                 # Загрузка CPU + uptime
free -m                                # RAM
df -h /overlay                         # Flash usage

# Все активные сервисы
for S in podkop sing-box dnsmasq adblock-lean ksmbd cron dropbear sqm; do
    echo "$S: $(/etc/init.d/$S status 2>&1 | head -1)"
done

# Подключённые DHCP-клиенты
cat /tmp/dhcp.leases

# Firewall — текущие nft-правила
nft list ruleset | less

# Процессы
ps
top -d 5
```

---

## 🔄 Backup / Restore / Upgrade

См. [docs/10-upgrades.md](10-upgrades.md)

```bash
# На ВАШЕМ ноутбуке (не на роутере):
./backup/backup.sh root@192.168.1.1               # Полный снапшот в backup/snapshots/
./backup/restore.sh backup/snapshots/20260417-120000 root@192.168.1.1

# После sysupgrade (новая прошивка OpenWrt):
ssh root@192.168.1.1 'sh -s' < setup/post-upgrade.sh   # Переустановить пакеты
```

---

## 🆘 Типовые «что-то сломалось — что нажать»

```bash
# 1. Сайт не открывается
vpn-mode status                  # В том ли я режиме?
awg show awg0 | grep handshake   # VPN живой?
logread | tail -50               # Последние события системы

# 2. Wi-Fi клиенты не подключаются
logread | grep hostapd | tail
wifi reload

# 3. Пропал DNS
dns-provider status
dns-provider cloudflare          # Попробовать фейловер
/etc/init.d/dnsmasq restart

# 4. Висит VPN (handshake старый)
ifdown awg0 && ifup awg0

# 5. Всё сломалось (nuclear option)
/etc/init.d/podkop restart
/etc/init.d/network restart
reboot                           # Крайний случай
```

---

## 📚 Полный справочник

- [docs/09-troubleshooting.md](09-troubleshooting.md) — глубокая диагностика
- [docs/10-upgrades.md](10-upgrades.md) — lifecycle обновлений
- [AGENTS.md](../AGENTS.md) — архитектурный контекст для AI-ассистентов и инженеров

---

*Держите эту страницу открытой во вкладке. 90% admin-операций на роутере — это одна из этих команд.*
