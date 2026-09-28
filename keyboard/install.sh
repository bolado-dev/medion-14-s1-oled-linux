#!/bin/bash
# Installs the medion_kbd serio driver: builds it, (optionally) signs it for
# Secure Boot, installs it + a systemd unit that binds it to serio0 on boot,
# and adds the i8042 kernel parameters the EC needs to keep the port alive.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "==> Building medion_kbd.ko"
make clean >/dev/null 2>&1 || true
make

if [ ! -f medion_kbd.ko ]; then
    echo "Build failed: medion_kbd.ko not produced." >&2
    exit 1
fi

SECURE_BOOT="unknown"
if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
        SECURE_BOOT="enabled"
    else
        SECURE_BOOT="disabled"
    fi
fi

if [ "$SECURE_BOOT" = "enabled" ]; then
    echo "==> Secure Boot is enabled: signing the module"
    bash ./sign_module.sh
fi

echo "==> Installing module"
install -d "/lib/modules/$(uname -r)/extra"
install -m 644 medion_kbd.ko "/lib/modules/$(uname -r)/extra/medion_kbd.ko"
depmod -a

echo "==> Installing loader script + systemd unit"
install -m 755 load_kbd_module.sh /usr/local/bin/load_kbd_module.sh
install -m 644 medion_kbd.service /etc/systemd/system/medion_kbd.service
systemctl daemon-reload
systemctl enable medion_kbd.service

echo "==> Adding required i8042 boot parameters"
GRUB_FILE=/etc/default/grub
PARAMS="i8042.nopnp=1 i8042.direct=1"
if [ -f "$GRUB_FILE" ]; then
    cp -n "$GRUB_FILE" "${GRUB_FILE}.bak-pre-medion-kbd" || true
    CURRENT="$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)"$/\1/' || true)"
    for p in i8042.nopnp=1 i8042.direct=1; do
        case " $CURRENT " in
            *" $p "*) ;;
            *) CURRENT="$CURRENT $p" ;;
        esac
    done
    CURRENT="$(echo "$CURRENT" | sed -E 's/^ +| +$//g')"
    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${CURRENT}\"|" "$GRUB_FILE"
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${CURRENT}\"" >> "$GRUB_FILE"
    fi
    update-grub
else
    echo "Warning: $GRUB_FILE not found, add '$PARAMS' to your bootloader config manually." >&2
fi

echo "==> Loading the driver now (for this session)"
modprobe medion_kbd || true
if [ -e /sys/bus/serio/devices/serio0/drvctl ]; then
    echo -n "none" > /sys/bus/serio/devices/serio0/drvctl || true
    echo -n "medion_kbd" > /sys/bus/serio/devices/serio0/drvctl || true
fi

echo
echo "Done. Reboot for the i8042 boot parameters to take full effect."
echo "After reboot, check with:  dmesg | grep medion_kbd"
