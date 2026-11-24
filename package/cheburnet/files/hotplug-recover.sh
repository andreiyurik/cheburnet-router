#!/bin/sh
# cheburnet: откатить установку, прерванную перезагрузкой (метка install.pending, см. install/recover.uc).
# Ставится пакетом, а не шагом firewall: при скачке питания файлы шагов могут не дойти до флеша.
[ "$ACTION" = "ifup" ] || exit 0
[ -f /etc/cheburnet/install.pending ] || exit 0
ucode -R /usr/share/cheburnet/engine/install/recover.uc >/dev/null 2>&1
exit 0
