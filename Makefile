# cheburnet-router — test targets
#
# Уровни тестов:
#   make lint             — T1: статика (shellcheck + sh -n + JSON).
#   make test-engine      — T2: юниты движка (чистая логика на ucode, host-only, секунды).
#   make test-netns       — T2.5: ПОВЕДЕНИЕ split-routing в netns (форвард-путь): реальное
#                            разделение трафика + kill-switch антиутечка на живом ядре, БЕЗ
#                            роутера/VPN. Rootless, секунды.
#   make poc-split        — Фаза 0 PoC: split-routing на примитивах в netns.
#   make qemu-v2          — T3a: hermetic VM smoke движка в qemu/KVM (~2мин, без интернета).
#   make qemu-webui-v2    — T3b: VM smoke с HTTP/ubus через uhttpd + UI (~3мин, нужен интернет).
#   make qemu-install-v2  — T3c: DEPENDS + data-plane против реальных сервисов (~5-8мин,
#                            нужен интернет). Release-gate.
#   make qemu-rollback-v2 — T3g: ПОЛНАЯ установка через ubus + откат при мёртвом сервере
#                            (~5-8мин, интернет). Единственная живая проверка оркестратора.
#   make qemu-reboot-v2   — T3h: конфигурация переживает перезагрузку роутера (~6-9мин, интернет).
#   make qemu-reality-v2  — T3d: обвязка VLESS+Reality на живом OpenWrt (~4-6мин, интернет).
#   make qemu-hysteria-v2 — T3e: обвязка Hysteria2 + замер веса Full-тира (~4-6мин, интернет).
#   make qemu-netem-v2    — T3f: ЗАМЕР goodput/CPU при потерях (netem), QUIC против TCP
#                            (~6-10мин, интернет). Печатает цифры, релиз не гейтит.
#   make qemu-live-vps    — T4a: трафик НАСКВОЗЬ через настоящий сервер Full-тира. Нужен
#                            поднятый стенд (tests/vps/) — не для CI.
#   make qemu-live-install— T4b: успешная установка целиком + ребут поверх неё (стенд tests/vps/).

.PHONY: lint test-engine test-netns test-shell poc-split qemu-v2 qemu-webui-v2 qemu-install-v2 qemu-rollback-v2 qemu-reboot-v2 qemu-reality-v2 qemu-hysteria-v2 qemu-netem-v2 qemu-live-vps qemu-live-install

lint:
	@bash tests/lint.sh

# Юнит-тесты движка (чистая логика на ucode, секунды, без роутера).
test-engine:
	@sh engine/run-tests.sh

# Тесты shell-скриптов роутера с изоляцией через фейки (без сети/пакетов): ретраи/код
# выхода install-singbox.sh (кнопка Full-тира) — самое глючеопасное место.
test-shell:
	@bash tests/install-singbox-test.sh

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

# T3a-v2 — hermetic VM smoke для движка v2 (ucode). Деплоит движок как пакет
# (shim + engine без tests/, ACL из реестра) и проверяет на живом OpenWrt:
# ubus-методы, границу доверия сквозь rpcd, rootpass→session.login,
# family on/off на реальном uci, NAT-зону + nft-цепочки + teardown на реальном fw4.
qemu-v2:
	@./tests/qemu/smoke-v2.sh

# T3c-v2 — установка зависимостей через apk + data-plane против РЕАЛЬНЫХ сервисов
# (dnsmasq-full/https-dns-proxy). Единственная проверка DEPENDS пакета из живого
# feed'а. Нужен интернет для apk. ~5-8 мин с KVM.
qemu-install-v2:
	@./tests/qemu/install-v2.sh

# T3b-v2 — HTTP-слой веб-мастера v2: uhttpd раздаёт Svelte-бандл, /ubus
# JSON-RPC (путь браузера), ACL anon-vs-admin, session.login, handler-валидация
# без деструктивных эффектов. Нужен интернет в VM (apk add uhttpd-mod-ubus).
qemu-webui-v2:
	@./tests/qemu/webui-v2.sh

# T3g-v2 — ПОЛНАЯ установка через ubus и ОТКАТ на живом OpenWrt: оркестратор доходит до
# health-check, мёртвый сервер НЕ выдаётся за успех, steps/vpn/apply.uc применяется
# по-настоящему (kmod в ядре), откат возвращает network/dnsmasq/install.json как было,
# токен остаётся, интернет на роутере цел. Рабочий VPN-сервер НЕ нужен — это и есть
# случай «сервера нет». Нужен интернет для apk. ~5-8 мин с KVM.
qemu-rollback-v2:
	@./tests/qemu/rollback-v2.sh

# T3h-v2 — data-plane ПЕРЕЖИВАЕТ ПЕРЕЗАГРУЗКУ: kill-switch и наборы возвращаются в ядро сами
# (правила в /etc/nftables.d, а не в памяти), dnsmasq/https-dns-proxy стартуют по procd, мост
# «домен→IP→набор» работает после загрузки. fw4 reload покрыт install-v2, но полный ребут со
# всеми init-скриптами — нет, а он случается у каждого. Рабочий VPN-сервер НЕ нужен.
# Нужен интернет для apk. ~6-9 мин с KVM.
qemu-reboot-v2:
	@./tests/qemu/reboot-v2.sh

# T3d-v2 — Full-тир (VLESS+Reality) data-plane WIRING на живом OpenWrt: singbox-шаг
# применяет config.json + netifd-маршрут singtun0 (half-routes), connectivity-probe
# корректно отвергает недостижимый сервер (fail-safe), teardown чистит. Рабочий
# Reality-сервер НЕ нужен (герметично). Нужен интернет для apk. ~4-6 мин с KVM.
qemu-reality-v2:
	@./tests/qemu/reality-v2.sh

# T3e-v2 — Hysteria2 (Full-тир) на живом OpenWrt: сборка sing-box-tiny РЕАЛЬНО умеет hysteria2
# (sing-box check принимает наш конфиг), port hopping доезжает в server_ports, TUN и маршруты
# встают, битый конфиг отвергается ДО подмены рабочего, проба отвергает мёртвый туннель,
# teardown чистит. Плюс ЗАМЕР веса Full-тира и сверка с порогом preflight в обе стороны.
# Рабочий Hysteria2-сервер НЕ нужен. Нужен интернет для apk. ~4-6 мин с KVM.
qemu-hysteria-v2:
	@./tests/qemu/hysteria-v2.sh

# T3f-v2 — ЗАМЕР ради которого Hysteria2 и берут: goodput и CPU при tc netem loss 0/5/15 %.
# Герметичный стенд целиком внутри VM (netns-сервер + veth + netem): QUIC (наш сгенерированный
# hysteria2-конфиг) против TCP через тот же sing-box, плюс baseline без туннеля. Печатает цифры
# для ADR 0004; релиз по ним НЕ гейтится (железо CI разное). Нужен интернет. ~6-10 мин с KVM.
qemu-netem-v2:
	@./tests/qemu/netem-v2.sh

# T4a — единственная проверка, доказывающая не «обвязка применилась», а «байты дошли до интернета
# через туннель»: тянем «какой у меня IP» ЧЕРЕЗ туннель и сверяем с адресом VPS, плюс крупная
# загрузка (ловит фрагментацию/PMTU). Нужен поднятый стенд: tests/vps/provision-lab.sh на чистом
# VPS (ключи он генерирует сам) + tests/vps/fetch-links.sh. В CI НЕ входит — зависит от
# арендованного сервера, см. tests/vps/README.md.
qemu-live-vps:
	@./tests/qemu/live-vps.sh

# T4b — УСПЕШНАЯ установка целиком через ubus против живого сервера + ПЕРЕЗАГРУЗКА поверх неё:
# commit-ветка оркестратора (install.json записан, одноразовый токен снят, панель честна), трафик
# выходит через сервер ДО и ПОСЛЕ ребута, туннель поднимается сам. T3g покрывает обратную ветку
# (провал+откат), а эту без рабочего сервера проверить нечем. Нужен стенд tests/vps/. Не для CI.
qemu-live-install:
	@./tests/qemu/live-install-v2.sh
