#!/bin/sh
# wget-via-curl.sh — подкладывается как `wget` на PATH для vendored awg-инсталлятора (bootstrap.sh).
# ШРАМ (2026-11): uclient-fetch (штатный wget OpenWrt) виснет на github.com, curl на том же mbedTLS проходит.
# Понимает ровно вызов инсталлятора: wget -q -O FILE URL.
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -O) out="$2"; shift ;;
        -*) ;;
        *) url="$1" ;;
    esac
    shift
done
[ -n "$out" ] && [ -n "$url" ] || exit 1
exec curl -fsSL --connect-timeout 15 -m 300 -o "$out" "$url"
