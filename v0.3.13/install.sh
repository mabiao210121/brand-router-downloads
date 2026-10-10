#!/bin/sh
set -eu
umask 077
[ "$(id -u)" = 0 ] || { echo 'root_required' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl_required' >&2; exit 1; }
BASE=https://license.wanyushoperp.com/updates/v0.3.13
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
fetch brand-router-0.3.13.tar.gz 4999f209e13b90688e9b838f0d67f9d8914362d2eb592c6418101f8c29da57b9
fetch setup-panel.lua bcfda32ff86c8b1284b8dd01b35722175804b6db11318fa442149aec74b99401
fetch issuer-public.json 7a8df51ce242d2c3ed7e5e3da8b8ad9257d443e7609107e33088fb2ee91a0ed2
tar -xzf "$WORK/brand-router-0.3.13.tar.gz" -C "$WORK"
sh "$WORK/brand-router-0.3.13/install.sh" "$MODE"
if [ "$MODE" = apply ]; then
    lua "$WORK/setup-panel.lua" < "$WORK/issuer-public.json"
    echo 'LAN management: http://gkglht.local (connect to this router LAN; HTTPS certificate may require local trust).'
    if [ -f /etc/brand-router/entry-id ]; then
        entry_id=$(cat /etc/brand-router/entry-id)
        case "$entry_id" in ????????) case "$entry_id" in *[!a-f0-9]*) ;; *) echo "Unique LAN entry: http://gkglht-$entry_id.local";; esac;; esac
    fi
    echo 'Save the one-time recovery code above. Account: root. After activation, choose a password or explicitly choose passwordless login.'
fi
