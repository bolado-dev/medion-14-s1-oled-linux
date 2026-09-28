#!/bin/bash
# Fixes BAT0._BST always reporting "Discharging" on the MEDION 14 S1 OLED
# (board NM14RPL) by patching a copy of the DSDT and loading it as an
# ACPI table override via the initrd, following the documented Linux
# mechanism (Documentation/admin-guide/acpi/initrd_table_override.rst).
#
# Safety model: this NEVER touches your default boot entry. It builds a
# separate, clearly-named GRUB menu entry so you can test it first. Once
# you've confirmed it works, promote it with --make-default.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="/root/medion-battery-fix-build"
KVER="$(uname -r)"
ENTRY_TITLE="MEDION 14 S1 OLED (battery charging fix)"
MARKER="### medion-battery-charging-fix ###"

MAKE_DEFAULT=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --make-default) MAKE_DEFAULT=1 ;;
        --force) FORCE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

BOARD="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
if [ "$BOARD" != "NM14RPL" ] && [ "$FORCE" -ne 1 ]; then
    echo "This fix targets board NM14RPL (MEDION 14 S1 OLED)." >&2
    echo "Detected board: '${BOARD:-unknown}'. Refusing to continue." >&2
    echo "If you have verified the same DSDT bug on your own board, re-run with --force." >&2
    exit 1
fi

command -v iasl >/dev/null 2>&1 || { echo "Installing acpica-tools (provides iasl)..."; apt-get update -qq && apt-get install -y acpica-tools; }
command -v cpio >/dev/null 2>&1 || { echo "Installing cpio..."; apt-get update -qq && apt-get install -y cpio; }

rm -rf "$WORK"
mkdir -p "$WORK"

echo "==> Dumping the live DSDT"
cp /sys/firmware/acpi/tables/DSDT "$WORK/dsdt.dat"

echo "==> Disassembling"
(cd "$WORK" && iasl -d dsdt.dat >/dev/null)

echo "==> Applying the _BST charging-state patch"
python3 "$DIR/patch_bst.py" "$WORK/dsdt.dsl"

echo "==> Recompiling"
(cd "$WORK" && iasl -tc dsdt.dsl)
if [ ! -f "$WORK/dsdt.aml" ]; then
    echo "Compilation failed, aborting." >&2
    exit 1
fi

echo "==> Building the ACPI table override initrd"
rm -rf "$WORK/override"
mkdir -p "$WORK/override/kernel/firmware/acpi"
cp "$WORK/dsdt.aml" "$WORK/override/kernel/firmware/acpi/dsdt.aml"
(cd "$WORK/override" && find kernel | cpio -H newc --create > "$WORK/acpi_override.cpio")

ORIG_INITRD="/boot/initrd.img-${KVER}"
NEW_INITRD="/boot/initrd.img-${KVER}-battery-fix"
cat "$WORK/acpi_override.cpio" "$ORIG_INITRD" > "$NEW_INITRD"
chmod 644 "$NEW_INITRD"

echo "==> Writing the GRUB test entry (/boot/grub/custom.cfg)"
ROOTUUID="$(findmnt -n -o UUID /)"
# Reuse whatever kernel parameters are already active (e.g. the i8042
# parameters added by the keyboard fix), so we don't regress them.
BOOT_PARAMS="$(sed -E 's/^BOOT_IMAGE=\S+\s*//; s/\s*root=\S+\s*//' /proc/cmdline)"

touch /boot/grub/custom.cfg
if ! grep -q "$MARKER" /boot/grub/custom.cfg; then
    cat >> /boot/grub/custom.cfg <<EOF

$MARKER
menuentry '${ENTRY_TITLE}' {
    load_video
    insmod gzio
    insmod part_gpt
    insmod ext2
    linux /boot/vmlinuz-${KVER} root=UUID=${ROOTUUID} ${BOOT_PARAMS}
    initrd ${NEW_INITRD}
}
EOF
fi

echo "==> Regenerating grub.cfg"
update-grub

if [ "$MAKE_DEFAULT" -eq 1 ]; then
    echo "==> Setting '${ENTRY_TITLE}' as the default boot entry"
    cp -n /etc/default/grub /etc/default/grub.bak-pre-battery-fix || true
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
        sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${ENTRY_TITLE}\"|" /etc/default/grub
    else
        echo "GRUB_DEFAULT=\"${ENTRY_TITLE}\"" >> /etc/default/grub
    fi
    update-grub
    echo "Done. It will boot into the fix automatically from now on."
else
    echo
    echo "Done. Reboot and manually select '${ENTRY_TITLE}' from the GRUB menu"
    echo "to test it (your normal entry is untouched and stays default)."
    echo
    echo "Once you've confirmed 'cat /sys/class/power_supply/BAT0/status' says"
    echo "Charging while plugged in, make it permanent with:"
    echo "  sudo bash $DIR/install.sh --make-default"
fi
