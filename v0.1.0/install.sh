#!/bin/sh
set -eu
umask 077
[ "$(id -u)" = 0 ] || { echo 'root_required' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl_required' >&2; exit 1; }
BASE=https://raw.githubusercontent.com/mabiao210121/brand-router-downloads/main/v0.1.0
MODE=${1:-apply}
case "$MODE" in plan|apply) ;; *) echo 'use_plan_or_apply' >&2; exit 1;; esac
WORK=$(mktemp -d /tmp/brand-download.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() {
    curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 \
        --max-filesize 16777216 --silent --show-error "$BASE/$1" -o "$WORK/$1"
    printf '%s  %s\n' "$2" "$WORK/$1" | sha256sum -c - >/dev/null || { echo 'download_checksum_failed' >&2; exit 1; }
}
fetch brand-router-0.1.0.tar.gz 4207e9340452332fc5a29c753aab1e7fcebeedeec9c60f6b4ce86f1138df8f02
fetch setup-panel.lua 53c46da9285387a791f87dbd38789f5e22c23288a389d4eaa948a35ba00b5509
fetch issuer-public.json 7a8df51ce242d2c3ed7e5e3da8b8ad9257d443e7609107e33088fb2ee91a0ed2
tar -xzf "$WORK/brand-router-0.1.0.tar.gz" -C "$WORK"
sh "$WORK/brand-router-0.1.0/install.sh" "$MODE"
if [ "$MODE" = apply ]; then
    lua "$WORK/setup-panel.lua" < "$WORK/issuer-public.json"
    echo 'Save the customer password above. Activate using your administrator-issued code.'
fi
