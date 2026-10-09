#!/bin/sh
set -eu
umask 077
[ "$(id -u)" = 0 ] || { echo 'root_required' >&2; exit 1; }
command -v curl >/dev/null || { echo 'curl_required' >&2; exit 1; }
BASE=https://raw.githubusercontent.com/mabiao210121/brand-router-downloads/main/v0.3.7
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
fetch brand-router-0.3.7.tar.gz dd8e0fbfdfcb069944055a5cbe12005f9ae5c3e72875abcabd21dd8296c07230
fetch setup-panel.lua 09abf1d25459b10e8beec843f3dd163703b9dd5158f8108fb8f9e19ae9bd8b24
fetch issuer-public.json 7a8df51ce242d2c3ed7e5e3da8b8ad9257d443e7609107e33088fb2ee91a0ed2
tar -xzf "$WORK/brand-router-0.3.7.tar.gz" -C "$WORK"
sh "$WORK/brand-router-0.3.7/install.sh" "$MODE"
if [ "$MODE" = apply ]; then
    lua "$WORK/setup-panel.lua" < "$WORK/issuer-public.json"
    echo 'Save the one-time recovery code above. Account: root. After activation, choose a password or explicitly choose passwordless login.'
fi
