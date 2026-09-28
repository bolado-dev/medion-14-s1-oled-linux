#!/bin/bash
# Removes the battery-charging-fix GRUB entry and restores the default
# boot entry, without touching your original kernel/initrd.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

KVER="$(uname -r)"
MARKER="### medion-battery-charging-fix ###"

echo "==> Restoring GRUB_DEFAULT"
if [ -f /etc/default/grub.bak-pre-battery-fix ]; then
    cp /etc/default/grub.bak-pre-battery-fix /etc/default/grub
    echo "Restored /etc/default/grub from backup."
else
    sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
    echo 'GRUB_DEFAULT=0' >> /etc/default/grub
fi

echo "==> Removing the custom.cfg entry"
if [ -f /boot/grub/custom.cfg ]; then
    # Delete from the marker line through the matching closing brace.
    awk -v marker="$MARKER" '
        $0 == marker {skip=1}
        skip && /^}/ {skip=0; next}
        !skip {print}
    ' /boot/grub/custom.cfg > /boot/grub/custom.cfg.tmp
    mv /boot/grub/custom.cfg.tmp /boot/grub/custom.cfg
fi

echo "==> Removing the override initrd"
rm -f "/boot/initrd.img-${KVER}-battery-fix"

echo "==> Regenerating grub.cfg"
update-grub

echo "Done. The next boot will use your original DSDT again."
