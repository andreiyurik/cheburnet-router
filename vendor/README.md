# vendor/

Запасные копии внешних установщиков, которые мы вызываем из `setup/`.

## Зачем

Основной источник — `raw.githubusercontent.com` — периодически блокируется
российскими провайдерами на DPI-уровне. У пользователя без рабочего VPN
(а на этапе установки VPN ещё нет!) `wget` молча зависает на 60 сек,
потом fail. Для этой ситуации `setup/02-podkop.sh` и `setup/03-adblock.sh`
сначала пробуют upstream, и при ошибке — берут локальную копию отсюда.

## Файлы

| Файл | Источник | Когда обновлять |
|---|---|---|
| `podkop-install.sh` | `github.com/itdoginfo/podkop` (`main`, `install.sh`) | если upstream добавил критическое исправление, и старая версия уже не ставится на свежие OpenWrt |
| `abl-install.sh` | `github.com/lynxthecat/adblock-lean` (`master`, `abl-install.sh`) | то же самое |

## Как обновить

```sh
cd vendor/
wget -O podkop-install.sh \
    https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh
wget -O abl-install.sh \
    https://raw.githubusercontent.com/lynxthecat/adblock-lean/master/abl-install.sh
```

После обновления — обкатать на тест-роутере и закоммитить.
