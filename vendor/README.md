# vendor/

Запасные/pinned-копии внешних установщиков, которые мы вызываем при установке.

## Зачем

Две причины держать копию, а не звать upstream вживую:

1. **DPI-блокировки (v1).** `raw.githubusercontent.com` периодически блокируют российские
   провайдеры. У пользователя без рабочего VPN (а на этапе установки VPN ещё нет!) `wget`
   молча зависает на 60 сек, потом fail. Поэтому `setup/02-podkop.sh` и `setup/03-adblock.sh`
   сначала пробуют upstream, при ошибке — берут локальную копию отсюда.
2. **Воспроизводимость и supply-chain (v2).** `amneziawg-install.sh` мы **пинуем** к конкретному
   коммиту и ревьюим его в нашем репо: `bootstrap.sh` берёт именно эту копию (один origin доверия,
   upstream `master` не «уезжает» под нами). Обновление — осознанный коммит, не авто-подтяжка.

## Файлы

| Файл | Источник | Пин | Когда обновлять |
|---|---|---|---|
| `podkop-install.sh` | `github.com/itdoginfo/podkop` (`main`, `install.sh`) | ветка | если upstream добавил критическое исправление, и старая версия уже не ставится на свежие OpenWrt |
| `abl-install.sh` | `github.com/lynxthecat/adblock-lean` (`master`, `abl-install.sh`) | ветка | то же самое |
| `amneziawg-install.sh` | `github.com/Slava-Shchipunov/awg-openwrt` (`amneziawg-install.sh`) | коммит `9742aa5` (релиз `v25.12.5`) | вышел `kmod-amneziawg` под новую OpenWrt-версию, либо upstream сменил схему имён/URL релиз-ассетов |

> ⚠️ **Vendored-копии устаревают вручную** (структурный долг, см. CLAUDE.md). Особенно
> `amneziawg-install.sh`: он строит URL релиза `.../releases/download/v${VERSION}/…` — если
> upstream переименует ассеты, пин сломается на новых OpenWrt. Бампить при апгрейде OpenWrt-веток.

## Как обновить

```sh
cd vendor/
wget -O podkop-install.sh \
    https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh
wget -O abl-install.sh \
    https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh
# amneziawg-install.sh — пинуем к КОММИТУ (не master). Обнови SHA здесь и в vendor/README + bootstrap.sh:
AWG_PIN=9742aa540b72c4059dabe8e91366162a98499219
wget -O amneziawg-install.sh \
    "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/$AWG_PIN/amneziawg-install.sh"
```

После обновления — обкатать на тест-роутере (QEMU + реальное железо) и закоммитить.
