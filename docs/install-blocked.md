# Установка, когда провайдер блокирует загрузку пакетов

Установщик cheburnet падает с одной из ошибок:

```
wget: Failed to send request: Operation not permitted
apk update: download failed
```

Это **DPI у твоего провайдера** режет `downloads.openwrt.org`. Типично в РФ
в 2024–2026. Cheburnet сам это обойти не может — он ещё не установлен.

**Решение:** на 10 минут установки подними интернет через стороннее
устройство с VPN, и используй его как WAN роутера. После установки
cheburnet поднимет свой AmneziaWG-туннель и проблема исчезнет навсегда.

Два варианта. **Сначала пробуй Вариант A (ноутбук) — он работает почти
всегда.** Вариант B (Android+USB) — только если нет ноутбука с Ethernet.

---

## Вариант A: Ноутбук с AmneziaVPN ✅ рекомендую

### Что нужно

- Ноутбук рядом с роутером.
- Ethernet-кабель (тот же, что обычно в WAN-порту роутера).
- **Если на ноуте нет Ethernet** — переходник USB-Ethernet (~$8).

### Шаги

1. **На ноутбуке — AmneziaVPN:**
   - Скачай: [amnezia.org](https://amnezia.org/downloads) (macOS / Windows / Linux).
   - Подключись к серверу (бесплатные на выбор есть в приложении).
   - Открой в браузере `ifconfig.me` — должен показать НЕ твой реальный IP.

2. **Включи Internet Sharing на Ethernet-порт:**
   - **macOS:** Settings → General → Sharing → Internet Sharing →  
     «Share connection from» = AmneziaVPN, «To computers using» = Ethernet.
   - **Windows:** Панель управления → Сеть → правый клик на AmneziaVPN-адаптере →  
     Properties → Sharing → «Allow other network users…» → выбери свой Ethernet.
   - **Linux (GNOME):** Settings → Network → Ethernet → ⚙️ → IPv4 → **Shared to other computers**.

3. **Переткни WAN-кабель cheburnet'а:**
   Один конец остаётся в WAN-порту роутера, другой — в Ethernet-порт ноута.
   Подожди 15 секунд (роутер получит IP от ноута).

4. **Запусти ту же команду установки cheburnet снова** (см. README).

5. **После успешной установки** — переткни WAN-кабель обратно в домашний роутер.
   На ноуте можно выключить AmneziaVPN и Internet Sharing. Cheburnet дальше
   сам ходит через свой AmneziaWG.

---

## Вариант B: Android-телефон + USB + AmneziaVPN

⚠ **Важно:** по умолчанию Android-tethering **НЕ** заворачивает трафик
подключённого устройства в VPN. Будут идти твои реальные пакеты с DPI,
и установка снова упадёт. Нужно явно включить «Always-on VPN» в системных
настройках Android — это форсит весь трафик (включая tethered) через VPN.

### Что нужно

- Роутер с USB-портом.
- USB-кабель с поддержкой данных (зарядный обычно НЕ подходит).
- Android-телефон с установленным AmneziaVPN.

### Шаги

1. **AmneziaVPN на Android — настрой full tunnel:**
   - Скачай AmneziaVPN из Google Play или с amnezia.org.
   - Подключись к серверу.

2. **Включи Always-on VPN (важно!):**
   - Android Settings → Network & Internet → VPN → AmneziaVPN → ⚙️.
   - Включи **Always-on VPN**.
   - Включи **Block connections without VPN** (это и есть ключевая опция —
     запрещает любому трафику идти мимо туннеля, включая tethered).

3. **Включи USB-tethering:**
   - Android Settings → Network & Internet → Hotspot & Tethering →  
     **USB tethering** = ON.

4. **Воткни USB-кабель: телефон → USB-порт роутера.**  
   Подожди 15–30 секунд.

5. **Запусти ту же команду установки cheburnet снова** (см. README).

6. **После успешной установки** — отключи USB-кабель, выключи tethering
   на телефоне.

### Не работает?

- **`usb0` не появляется на роутере** — стоковый OpenWrt 25.12 не всегда
  включает драйвер `kmod-usb-net-rndis` (нужен для Android-tether). В этом
  случае переключайся на **Вариант A**.
- **Трафик идёт мимо VPN** — Always-on VPN с галкой «Block connections
  without VPN» обязательны. На некоторых прошивках Android (особенно
  кастомных) эта опция спрятана глубже или вообще не работает. Снова —
  **Вариант A**.

---

## Не помогает / совсем ничего не работает

Напиши в Telegram: [@industrialprofi](https://t.me/industrialprofi).

Приложи:
- Модель роутера и провайдера.
- На каком шаге упало (последние 20 строк из терминала).
- Что пробовал из этого гайда.
