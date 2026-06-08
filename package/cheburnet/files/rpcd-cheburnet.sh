#!/bin/sh
# rpcd-cheburnet.sh — тонкий shim. rpcd подхватывает обработчики из /usr/libexec/rpcd/, но наш
# реальный обработчик — ucode в дереве движка (/usr/share/cheburnet/engine/ubus/rpcd-cheburnet),
# где работают его относительные import'ы (./ubus.uc) и sourcepath-вычисление пути к движку.
# Shim лишь запускает его, прокидывая аргументы rpcd (list / call <method>) и stdin.
# Ставится как /usr/libexec/rpcd/cheburnet (см. package/cheburnet/Makefile).
exec ucode -R /usr/share/cheburnet/engine/ubus/rpcd-cheburnet "$@"
