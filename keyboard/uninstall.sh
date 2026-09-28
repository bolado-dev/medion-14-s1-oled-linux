#!/bin/bash
# Removes the medion_kbd driver and its systemd unit. Does not remove the
# i8042.nopnp/i8042.direct boot parameters, since removing them will make
# the internal keyboard unresponsive again on this hardware.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

echo "==> Stopping and disabling service"
systemctl disable --now medion_kbd.service 2>/dev/null || true
rm -f /etc/systemd/system/medion_kbd.service
systemctl daemon-reload

echo "==> Removing module"
rmmod medion_kbd 2>/dev/null || true
rm -f "/lib/modules/$(uname -r)/extra/medion_kbd.ko"
depmod -a

rm -f /usr/local/bin/load_kbd_module.sh

echo "Done. The internal keyboard will fall back to being unresponsive"
echo "unless you also remove i8042.nopnp=1 i8042.direct=1 from your kernel"
echo "boot parameters (/etc/default/grub) -- only do that if you are not"
echo "planning to reinstall this driver."
