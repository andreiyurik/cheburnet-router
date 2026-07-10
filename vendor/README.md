# vendor/

Pinned-копия внешнего установщика, который `bootstrap.sh` вызывает при установке.

## Зачем

**Воспроизводимость и supply-chain.** `amneziawg-install.sh` мы **пинуем** к конкретному коммиту
и ревьюим его в нашем репо: `bootstrap.sh` берёт именно эту копию (один origin доверия, upstream
`master` не «уезжает» под нами). Обновление — осознанный коммит, не авто-подтяжка.

## Файлы

| Файл | Источник | Пин | Когда обновлять |
|---|---|---|---|
| `amneziawg-install.sh` | `github.com/Slava-Shchipunov/awg-openwrt` (`amneziawg-install.sh`) | коммит `9742aa5` (релиз `v25.12.5`) | вышел `kmod-amneziawg` под новую OpenWrt-версию, либо upstream сменил схему имён/URL релиз-ассетов |

> ⚠️ **Vendored-копия устаревает вручную** (структурный долг, см. CLAUDE.md). Она строит URL
> релиза `.../releases/download/v${VERSION}/…` — если upstream переименует ассеты, пин сломается
> на новых OpenWrt. Бампить при апгрейде OpenWrt-веток.

## Как обновить

```sh
cd vendor/
# Пинуем к КОММИТУ (не master). Обнови SHA здесь и в vendor/README + bootstrap.sh:
AWG_PIN=9742aa540b72c4059dabe8e91366162a98499219
wget -O amneziawg-install.sh \
    "https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/$AWG_PIN/amneziawg-install.sh"
```

После обновления — обкатать на тест-роутере (QEMU + реальное железо) и закоммитить.
