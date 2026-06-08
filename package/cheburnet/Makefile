# OpenWrt-пакет cheburnet — движок (ucode) + ubus-обработчик + ACL + веб-мастер.
#
# Собирается OpenWrt SDK (apk-based ветка, см. .github/workflows). Чистые скрипты — компилировать
# нечего: Build/Compile пуст, install копирует файлы из репозитория. PKGARCH:=all — пакет
# arch-независим (ucode интерпретируется), а arch-зависимые зависимости (kmod-amneziawg и т.п.)
# apk подбирает сам. Проверка реальной сборки/установки — фаза QEMU (отложена мейнтейнером).

include $(TOPDIR)/rules.mk

PKG_NAME:=cheburnet
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Andrey Yurik
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

# Корень репозитория относительно этого Makefile (package/cheburnet/Makefile). Feed в CI —
# src-link на репозиторий, поэтому ../.. указывает на корень с engine/ и package/files/.
CHEBURNET_REPO:=$(CURDIR)/../..

define Package/cheburnet
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=VPN
  TITLE:=cheburnet — образовательный split-tunnel роутер (мастер настройки)
  URL:=https://github.com/
  PKGARCH:=all
  # Движок и data-plane. dnsmasq-full — ради nftset; https-dns-proxy — шифрованный DNS;
  # kmod-amneziawg + amneziawg-tools — туннель; adblock-lean — блок-лист; nftables/ip-full —
  # пометка и policy routing; uhttpd-mod-ubus — мост браузер→ubus для веб-мастера.
  DEPENDS:= \
	+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus \
	+rpcd +rpcd-mod-file \
	+dnsmasq-full +https-dns-proxy +adblock-lean \
	+kmod-amneziawg +amneziawg-tools \
	+nftables +ip-full \
	+uhttpd +uhttpd-mod-ubus
endef

define Package/cheburnet/description
  Образовательный роутер на OpenWrt с настраиваемым split-tunnel: домены из direct-списка идут
  напрямую, остальной трафик — через зашифрованный VPN. Без sing-box: dnsmasq-nftset + nftables
  + policy routing + AmneziaWG. Логика — движок на ucode; настройка — веб-мастер через ubus RPC.
endef

# Скрипты — компилировать нечего.
define Build/Compile
endef

define Package/cheburnet/install
	# Движок (ucode): весь engine/, но без тестов, README и host-раннера — на роутере не нужны
	# и зря едят флеш. Структуру сохраняем — рабочие относительные import'ы между модулями.
	$(INSTALL_DIR) $(1)/usr/share/cheburnet
	$(CP) $(CHEBURNET_REPO)/engine $(1)/usr/share/cheburnet/
	$(FIND) $(1)/usr/share/cheburnet/engine -type d -name tests -prune -exec rm -rf {} +
	rm -f $(1)/usr/share/cheburnet/engine/run-tests.sh
	$(FIND) $(1)/usr/share/cheburnet/engine -name 'README.md' -delete

	# ubus-обработчик через тонкий shim в /usr/libexec/rpcd/ (rpcd сканирует только его).
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/rpcd-cheburnet.sh $(1)/usr/libexec/rpcd/cheburnet

	# ACL движка (выведена из реестра методов; см. engine/ubus/acl.uc).
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) $(CHEBURNET_REPO)/engine/ubus/rpcd-acl.json $(1)/usr/share/rpcd/acl.d/cheburnet.json

	# Веб-мастер (пока заглушка; SPA на Svelte — в фазе web).
	$(INSTALL_DIR) $(1)/www/cheburnet
	$(CP) ./files/web/. $(1)/www/cheburnet/
endef

# rpcd подхватит новый обработчик и ACL только после reload. На самом роутере (не в imagebuilder,
# где $IPKG_INSTROOT задан) — мягкий reload, без падения если rpcd ещё не запущен.
define Package/cheburnet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/rpcd reload 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,cheburnet))
