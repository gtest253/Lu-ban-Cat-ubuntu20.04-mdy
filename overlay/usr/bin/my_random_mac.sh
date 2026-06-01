#!/bin/bash

set -u

BOOT_MARK_DIR="${BOOT_MARK_DIR:-/boot}"
FORCE=0
MARKER_CREATED=0
VENDOR_LAN_MAC=""

usage() {
    echo "Usage: $0 [--force]" >&2
}

is_raw_mac() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{12}$'
}

is_colon_mac() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$'
}

generate_raw_mac() {
    printf '%01x2%02x%02x%02x%02x%02x' \
        $((RANDOM % 16)) \
        $((RANDOM % 256)) \
        $((RANDOM % 256)) \
        $((RANDOM % 256)) \
        $((RANDOM % 256)) \
        $((RANDOM % 256))
}

raw_to_colon_mac() {
    printf '%s' "$1" | tr 'A-F' 'a-f' | sed 's/../&:/g; s/:$//'
}

normalize_mac() {
    value=$(printf '%s' "$1" | tr 'A-F' 'a-f' | tr -d ' \t\r\n')

    if is_raw_mac "$value"; then
        RAW_MAC="$value"
        COLON_MAC=$(raw_to_colon_mac "$value")
        return 0
    fi

    if is_colon_mac "$value"; then
        COLON_MAC="$value"
        RAW_MAC=$(printf '%s' "$value" | tr -d ':')
        return 0
    fi

    return 1
}

is_native_gmac() {
    compatible="/sys/class/net/$1/device/of_node/compatible"
    [ -f "$compatible" ] && grep -aq 'gmac' "$compatible"
}

set_iface_mac() {
    iface="$1"
    mac="$2"

    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig "$iface" down || return 1
        ifconfig "$iface" hw ether "$mac" || return 1
        ifconfig "$iface" up || return 1
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        ip link set dev "$iface" down || return 1
        ip link set dev "$iface" address "$mac" || return 1
        ip link set dev "$iface" up || return 1
        return 0
    fi

    echo "Neither ip nor ifconfig is available." >&2
    return 1
}

ensure_marker_mac() {
    iface="$1"
    marker="$BOOT_MARK_DIR/boot_mac_$iface"
    native_gmac="$2"
    MARKER_CREATED=0

    if [ "$FORCE" -eq 1 ]; then
        rm -f "$marker"
    fi

    if [ ! -e "$marker" ]; then
        RAW_MAC=$(generate_raw_mac)
        COLON_MAC=$(raw_to_colon_mac "$RAW_MAC")

        if [ "$native_gmac" -eq 1 ]; then
            printf '%s\n' "$RAW_MAC" > "$marker"
        else
            printf '%s\n' "$COLON_MAC" > "$marker"
        fi

        MARKER_CREATED=1
    fi

    marker_value=$(sed -n '1p' "$marker" 2>/dev/null || true)
    if normalize_mac "$marker_value"; then
        return 0
    fi

    RAW_MAC=$(generate_raw_mac)
    COLON_MAC=$(raw_to_colon_mac "$RAW_MAC")

    if [ "$native_gmac" -eq 1 ]; then
        printf '%s\n' "$RAW_MAC" > "$marker"
    else
        printf '%s\n' "$COLON_MAC" > "$marker"
    fi

    MARKER_CREATED=1
}

apply_random_mac() {
    iface="$1"

    [ -d "/sys/class/net/$iface" ] || return 0

    native_gmac=0
    if is_native_gmac "$iface"; then
        native_gmac=1
    fi

    if ! ensure_marker_mac "$iface" "$native_gmac"; then
        echo "Failed to prepare marker MAC for $iface." >&2
        return 1
    fi

    if [ "$native_gmac" -eq 1 ]; then
        if [ "$MARKER_CREATED" -eq 0 ]; then
            return 0
        fi

        if ! set_iface_mac "$iface" "$COLON_MAC"; then
            echo "Failed to apply MAC $COLON_MAC to $iface." >&2
            return 1
        fi

        VENDOR_LAN_MAC="${VENDOR_LAN_MAC}${RAW_MAC}"
        if command -v vendor_storage >/dev/null 2>&1; then
            if ! vendor_storage -w VENDOR_LAN_MAC_ID -t hex -i "$VENDOR_LAN_MAC"; then
                echo "Failed to persist native GMAC MAC address for $iface." >&2
                return 1
            fi
        else
            echo "vendor_storage is not available; $iface was only updated for this boot." >&2
        fi

        echo "$iface native-gmac -> $COLON_MAC"
    else
        if ! set_iface_mac "$iface" "$COLON_MAC"; then
            echo "Failed to apply MAC $COLON_MAC to $iface." >&2
            return 1
        fi

        echo "$iface -> $COLON_MAC"
    fi

    return 0
}

case "${1:-}" in
    --force)
        FORCE=1
        shift
        ;;
    --help|-h)
        usage
        exit 0
        ;;
esac

if [ "$#" -ne 0 ]; then
    usage
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

if [ ! -d "$BOOT_MARK_DIR" ]; then
    echo "Marker directory $BOOT_MARK_DIR does not exist." >&2
    exit 1
fi

for iface in eth0 eth1 eth2 eth3; do
    apply_random_mac "$iface"
done

sync
