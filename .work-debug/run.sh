#!/bin/bash
# Debug: bring up VM, run vm_deploy_handler with extra diagnostics
set -u
cd /home/pingvinus/cheburnet-router
. tests/qemu/lib.sh

vm_lib_init
trap - EXIT
vm_prepare_image
vm_start
vm_boot_and_setup

echo "→ DEBUG: запускаю vm_deploy_handler"
vm_deploy_handler || echo "→ DEBUG: vm_deploy_handler failed rc=$?"

echo "→ DEBUG: что лежит в /opt/cheburnet/lib/"
vm_ssh "ls -la /opt/cheburnet/lib/"

echo "→ DEBUG: пробую запустить rpcd-cheburnet вручную с list"
vm_ssh "/usr/libexec/rpcd/cheburnet list 2>&1 | head -20"

echo "→ DEBUG: ubus list cheburnet"
vm_ssh "ubus list cheburnet" && echo "  list OK" || echo "  ✗ list failed"

echo "→ DEBUG: ubus -v list cheburnet (методы)"
vm_ssh 'ubus -v list cheburnet | sed -nE "s/^[[:space:]]+\"([^\"]+)\":.*/\\1/p" | sort'

echo "→ DEBUG: SSH порт ${SSH_PORT}, VM PID: ${QPID}"
