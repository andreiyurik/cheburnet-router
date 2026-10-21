# cheburnet-router — test targets
#
# Уровни тестов:
#   make lint             — T1: статика (shellcheck + sh -n + JSON).
#   make test-engine      — T2: юниты движка (чистая логика на ucode, host-only, секунды).
#   make test-netns       — T2.5: ПОВЕДЕНИЕ split-routing в netns (форвард-путь): реальное
#                            разделение трафика + kill-switch антиутечка на живом ядре, БЕЗ
#                            роутера/VPN. Rootless, секунды.
#   make poc-split        — Фаза 0 PoC: split-routing на примитивах в netns.
#   make qemu-smoke          — T3a: hermetic VM smoke движка в qemu/KVM (~2мин, без интернета).
#   make qemu-webui    — T3b: VM smoke с HTTP/ubus через uhttpd + UI (~3мин, нужен интернет).
#   make qemu-install  — T3c: DEPENDS + data-plane против реальных сервисов (~5-8мин,
#                            нужен интернет). Release-gate.
#   make qemu-rollback — T3g: ПОЛНАЯ установка через ubus + откат при мёртвом сервере
#                            (~5-8мин, интернет). Единственная живая проверка оркестратора.
#   make qemu-reboot   — T3h: конфигурация переживает перезагрузку роутера (~6-9мин, интернет).
#   make qemu-route-fallback — T3i: маршрут туннеля переживает переподключение WAN (~5-8мин, интернет).
#   make qemu-dns-fallback — T3j: DNS переживает смерть туннеля (~6-9мин, интернет).
#   make qemu-emergency    — T3k: аварийный режим возвращает интернет и обратим (~6-9мин, интернет).
#   make qemu-profiles — T3l: поля AWG 3.1 доходят до ядра; профили и автосмена откатываются (~5-8мин, интернет).
#   make qemu-live-install— T4b: успешная установка целиком + ребут поверх неё (стенд tests/vps/).

.PHONY: lint test-engine test-netns test-shell poc-split qemu-smoke qemu-webui qemu-install qemu-rollback qemu-reboot qemu-route-fallback qemu-dns-fallback qemu-emergency qemu-profiles qemu-live-install

lint:
	@bash tests/lint.sh

# Юнит-тесты движка (чистая логика на ucode, секунды, без роутера).
test-engine:
	@sh engine/run-tests.sh

# Тесты shell-скриптов роутера с изоляцией через фейки (без сети/пакетов): ретраи и код выхода bootstrap.
test-shell:
	@bash tests/bootstrap-test.sh

# T2.5 — поведение split-routing на живом ядре БЕЗ роутера/QEMU/VPN (форвард-путь в netns):
# direct→WAN, остальное→туннель, kill-switch антиутечка при мёртвом туннеле — для awg0 и singtun0.
# Гоняет РЕАЛЬНЫЙ вывод движка (tests/netns/emit.uc). Rootless (unshare -rn). Реальный dnsmasq→nftset,
# если есть dnsmasq/nslookup. Секунды; изоляция сценариев — свежий netns на каждый (ре-exec).
test-netns:
	@sh tests/netns/dataplane.sh

# Фаза 0 PoC + e2e: split-routing на примитивах И из реального вывода генератора,
# прогон через network namespace. Нужны nft/ip/unshare; ucode — для фазы B.
poc-split:
	@unshare -rn sh tests/poc/split-routing-netns.sh

# T3a — hermetic VM smoke для движка (ucode). Деплоит движок как пакет
# (shim + engine без tests/, ACL из реестра) и проверяет на живом OpenWrt:
# ubus-методы, границу доверия сквозь rpcd, rootpass→session.login,
# NAT-зону + nft-цепочки + teardown на реальном fw4.
qemu-smoke:
	@bash tests/qemu/smoke.sh

# T3c — установка зависимостей через apk + data-plane против РЕАЛЬНЫХ сервисов
# (dnsmasq-full/https-dns-proxy). Единственная проверка DEPENDS пакета из живого
# feed'а. Нужен интернет для apk. ~5-8 мин с KVM.
qemu-install:
	@bash tests/qemu/install.sh

# T3b — HTTP-слой веб-мастера: uhttpd раздаёт Svelte-бандл, /ubus
# JSON-RPC (путь браузера), ACL anon-vs-admin, session.login, handler-валидация
# без деструктивных эффектов. Нужен интернет в VM (apk add uhttpd-mod-ubus).
qemu-webui:
	@bash tests/qemu/webui.sh

# T3g — ПОЛНАЯ установка через ubus и ОТКАТ на живом OpenWrt: оркестратор доходит до
# health-check, мёртвый сервер НЕ выдаётся за успех, steps/vpn/apply.uc применяется
# по-настоящему (kmod в ядре), откат возвращает network/dnsmasq/install.json как было,
# токен остаётся, интернет на роутере цел. Рабочий VPN-сервер НЕ нужен — это и есть
# случай «сервера нет». Нужен интернет для apk. ~5-8 мин с KVM.
qemu-rollback:
	@bash tests/qemu/rollback.sh

# T3h — data-plane ПЕРЕЖИВАЕТ ПЕРЕЗАГРУЗКУ: kill-switch и наборы возвращаются в ядро сами
# (правила в /etc/nftables.d, а не в памяти), dnsmasq/https-dns-proxy стартуют по procd, мост
# «домен→IP→набор» работает после загрузки. fw4 reload покрыт install, но полный ребут со
# всеми init-скриптами — нет, а он случается у каждого. Рабочий VPN-сервер НЕ нужен.
# Нужен интернет для apk. ~6-9 мин с KVM.
qemu-reboot:
	@bash tests/qemu/reboot.sh

# T3i — маршрут туннеля ПЕРЕЖИВАЕТ ПЕРЕПОДКЛЮЧЕНИЕ WAN: half-routes выигрывают у WAN-дефолта,
# не удаляя его, поэтому подъём WAN не отбирает маршрут у туннеля (инцидент «сервер жив, роутер
# без интернета до перезагрузки»), а снятие туннеля не оставляет роутер без пути наружу.
# Рабочий VPN-сервер НЕ нужен. Нужен интернет для apk. ~5-8 мин с KVM.
qemu-route-fallback:
	@bash tests/qemu/route-fallback.sh

# T3j — DNS ПЕРЕЖИВАЕТ СМЕРТЬ ТУННЕЛЯ: два экземпляра DoH одного провайдера, резервный уводится
# мимо туннеля по владельцу сокета (`ip rule uidrange`), dnsmasq спрашивает их по порядку. Без
# этого мёртвый туннель уносил с собой ВЕСЬ резолв, включая домены из direct-списка, — то есть
# обещание панели «открываются сайты из списка напрямую» было ложным. Есть отрицательный контроль.
# Рабочий VPN-сервер НЕ нужен. Нужен интернет для apk. ~6-9 мин с KVM.
qemu-dns-fallback:
	@bash tests/qemu/dns-fallback.sh

# T3k — АВАРИЙНЫЙ РЕЖИМ: одна кнопка возвращает интернет, когда туннель не поднять, и вторая
# возвращает защиту. Проверяется и то, что защиту никто не возвращает молча (ни сторож, ни
# переприменение при подъёме WAN) — иначе человек снова остался бы без интернета, ничего не сделав.
# Живой VPN-сервер НЕ нужен (endpoint из RFC 5737 = «сервер умер»). ~6-9 мин с KVM.
qemu-emergency:
	@bash tests/qemu/emergency.sh

# T3l — AWG 3.1 и профили серверов: поля 3.1 доходят до модуля ядра, неполный конфиг отбивается,
# подключение молчащего сервера и автосмена откатываются честно (endpoint из RFC 5737). ~5-8 мин.
qemu-profiles:
	@bash tests/qemu/profiles.sh

# T4b — УСПЕШНАЯ установка целиком через ubus против живого сервера + ПЕРЕЗАГРУЗКА поверх неё:
# commit-ветка оркестратора (install.json записан, одноразовый токен снят, панель честна), трафик
# выходит через сервер ДО и ПОСЛЕ ребута, туннель поднимается сам. T3g покрывает обратную ветку
# (провал+откат), а эту без рабочего сервера проверить нечем. Нужен стенд tests/vps/. Не для CI.
qemu-live-install:
	@bash tests/qemu/live-install.sh
