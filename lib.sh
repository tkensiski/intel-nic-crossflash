#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 tkensiski
#
# Shared helpers for intel-nic-tool. Sourced, not executed.

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_rst=$'\033[0m'
log()  { printf '%s[*]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf -- '------------------------------------------------------------\n'; }

need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# confirm "prompt" -> 0 if the user agrees. Honors ASSUME_YES=1.
confirm() {
    [ "${ASSUME_YES:-0}" = "1" ] && { log "auto-confirm: $1"; return 0; }
    printf '%s [y/N] ' "$1"
    local ans; read -r ans </dev/tty || return 1
    case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; }

# Normalize a MAC to plain uppercase, no separators (001122334455).
mac_norm() { printf '%s' "$1" | tr -d ':-' | tr 'a-f' 'A-F'; }

# etrack id (uppercase, no 0x) from an interface's ethtool firmware-version.
# firmware-version line looks like: "5.40 0x80002e8d 18.0.14"
get_etrack() {
    ethtool -i "$1" 2>/dev/null | awk '
        /firmware-version/ {
            for (i = 1; i <= NF; i++) {
                t = $i; sub(/^0x/, "", t)
                if (t ~ /^8[0-9A-Fa-f]{7}$/) { print toupper(t); exit }
            }
        }'
}

# All Intel (vendor 8086) network interfaces, one per line.
find_intel_ifaces() {
    local n vendor
    for n in /sys/class/net/*; do
        [ -e "$n/device/vendor" ] || continue
        vendor=$(cat "$n/device/vendor" 2>/dev/null)
        [ "$vendor" = "0x8086" ] || continue
        basename "$n"
    done
}

# Interface name for a MAC (any separator/case). Prints name, returns 1 if none.
iface_for_mac() {
    local want n a
    want=$(mac_norm "$1" | tr 'A-F' 'a-f')
    for n in /sys/class/net/*; do
        [ -e "$n/address" ] || continue
        a=$(tr -d ':' < "$n/address" | tr 'A-F' 'a-f')
        [ "$a" = "$want" ] && { basename "$n"; return 0; }
    done
    return 1
}

# All Intel iface MACs on the same physical card as the given MAC -- i.e. every
# port sharing the same PCI domain:bus:device (any function). A dual-port NIC
# has one flash chip but bootutil tracks the boot-ROM enable state per port, and
# the BIOS dispatches every port that still advertises one, so disable-orom must
# hit them all. Falls back to just the input MAC if the slot can't be resolved.
sibling_macs() {
    local want base="" n slot a
    want=$(mac_norm "$1" | tr 'A-F' 'a-f')
    for n in /sys/class/net/*; do
        [ -e "$n/address" ] || continue
        a=$(tr -d ':' < "$n/address" | tr 'A-F' 'a-f')
        [ "$a" = "$want" ] || continue
        slot=$(basename "$(readlink -f "$n/device")"); base=${slot%.*}; break
    done
    # one MAC per line -- mac_norm itself prints no trailing newline, so emit it
    # here or the ports concatenate into a single bogus token.
    [ -n "$base" ] || { printf '%s\n' "$(mac_norm "$1")"; return; }
    for n in /sys/class/net/*; do
        [ -e "$n/device" ] || continue
        slot=$(basename "$(readlink -f "$n/device")")
        [ "${slot%.*}" = "$base" ] || continue
        printf '%s\n' "$(mac_norm "$(cat "$n/address")")"
    done
}

# bootutil NIC index for a MAC. $1=bootutil dir, $2=MAC (any format).
# bootutil columns: Port  NetworkAddress  Location ...  (MAC has no separators)
bootutil_nic_for_mac() {
    local dir="$1" mac; mac=$(mac_norm "$2")
    "$dir/bootutil64e" 2>/dev/null | awk -v m="$mac" '$2 == m { print $1; exit }'
}

# Most recent verified backup file in WORK_DIR for a MAC.
latest_backup() { ls -t "${WORK_DIR}/$(mac_norm "$1")"_*.nvm 2>/dev/null | head -1; }

# Append an etrack id to the REPLACES line of the cfg block whose NVM IMAGE
# matches $2. Idempotent. Preserves DOS (CRLF) line endings. Prints to stdout.
append_etrack_to_cfg() {
    awk -v img="$2" -v et="$3" '
        /^BEGIN DEVICE/ { istarget = 0 }
        index($0, "NVM IMAGE:") && index($0, img) { istarget = 1 }
        {
            if (istarget && $0 ~ /^REPLACES:/ && index($0, et) == 0) {
                cr = ""; line = $0
                if (line ~ /\r$/) { cr = "\r"; sub(/\r$/, "", line) }
                $0 = line " " et cr
                istarget = 0
            }
            print
        }
    ' "$1"
}
