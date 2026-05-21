#!/bin/bash
# Launcher для qemu-install с явным cleanup и логированием.
set -u
cd /home/pingvinus/cheburnet-router

pkill -9 -f "qemu-system-x86_64.*disk.img" 2>/dev/null || true
sleep 2

echo "=== launching tests/qemu/install.sh at $(date) ==="
bash tests/qemu/install.sh 2>&1
echo "=== finished at $(date), rc=$? ==="
