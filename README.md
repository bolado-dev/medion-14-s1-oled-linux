# MEDION 14 S1 OLED — Linux fixes

Two hardware-specific fixes for the **MEDION 14 S1 OLED** laptop (board
`NM14RPL`, a Tongfang/Clevo barebone) running Linux, built by reverse
engineering the vendor's embedded controller (EC) firmware:

1. **Keyboard driver** — the internal keyboard is unusable out of the box
   (scrambled scancodes, inverted arrow keys) and the Caps/Num/Scroll Lock
   LEDs never light up, even in distros where community workarounds fix
   the scancodes.
2. **Battery charging-state fix** — `BAT0` always reports `Discharging`,
   even while genuinely charging on AC power, so desktop environments
   never show a charging icon.

Both are firmware bugs in this specific model, not distro bugs — they
reproduce identically on Fedora, Debian and Kali. Each fix is documented
below with the actual debugging process, not just the result.

> **This repo is hardware-specific.** It patches this laptop's ACPI
> tables and binds a custom kernel driver to its keyboard port. Read the
> [Safety](#safety) section before running anything.

## Table of contents

- [Install](#install)
- [Bug 1: unusable keyboard + no Caps Lock LED](#bug-1-unusable-keyboard--no-caps-lock-led)
- [Bug 2: battery never reports "Charging"](#bug-2-battery-never-reports-charging)
- [Safety](#safety)
- [Uninstall](#uninstall)
- [Credits](#credits)

## Install

```bash
git clone https://github.com/<your-username>/medion-14-s1-oled-linux.git
cd medion-14-s1-oled-linux
./install.sh
```

`install.sh` is an interactive menu (built with [`gum`](https://github.com/charmbracelet/gum),
installed automatically on request — falls back to a plain text menu if
you decline) that lets you install either fix independently, both at
once, or uninstall them:

```
┌──────────────────────────────────────────────────────────┐
│  MEDION 14 S1 OLED — Linux fixes                          │
│  Custom serio keyboard driver + ACPI battery charging fix │
└──────────────────────────────────────────────────────────┘

? ¿Qué quieres instalar?
> Fix de teclado (scancodes + LED Bloq Mayús)
  Fix de batería (icono de carga en la barra)
  Instalar ambos
  Desinstalar fix de teclado
  Desinstalar fix de batería
  Salir
```

Each fix also ships its own standalone `install.sh` / `uninstall.sh` in
its subdirectory if you'd rather run them directly (see below).

Requires: `gcc`, `make`, your kernel headers package, `acpica-tools`
(`iasl`), `cpio` — the installers will offer to install what's missing
via `apt`.

## Bug 1: unusable keyboard + no Caps Lock LED

### The bug

Out of the box, the internal keyboard on this laptop is barely usable:

- Scancodes are scrambled (pressing `A` types something else entirely).
- `Up` / `Down` / `Right` and `AltGr` report press/release **inverted**.
- The kernel's `atkbd` driver sometimes leaves `serio0` idle shortly
  after boot, so the keyboard just stops responding.

This is a firmware quirk: the EC talks a non-standard flavor of the AT
Set 1 scancode protocol that `atkbd` doesn't know how to interpret. It's
not distro-specific — it's reported identically by other users of this
exact model on Fedora and Debian forums.

### The fix

[`keyboard/medion_kbd.c`](keyboard/medion_kbd.c) is a custom `serio`
driver that binds directly to `serio0`, decodes the raw scancodes itself
(including the inverted Alt/arrow keys), and reports proper key events
to the input subsystem. It needs `i8042.nopnp=1 i8042.direct=1` on the
kernel command line so the platform's ACPI doesn't disable the port
before the driver can claim it.

The base scancode-translation table was adapted from the community
driver at [mrelmida/medion-signium-keyboard](https://github.com/mrelmida/medion-signium-keyboard).

### What this repo adds: the Caps Lock LED

Even with the scancode fix applied, the keyboard LEDs never lit up.
Tracing it down: the driver only ever registered `EV_KEY` capabilities on
its `input_dev` — it never told the input subsystem it supported
`EV_LED`, and never implemented the standard AT `0xED` SETLEDS command to
report LED state back to the EC. `medion_kbd.c` in this repo adds both:

```c
__set_bit(EV_LED, input_dev->evbit);
__set_bit(LED_CAPSL, input_dev->ledbit);
__set_bit(LED_NUML, input_dev->ledbit);
__set_bit(LED_SCROLLL, input_dev->ledbit);
input_dev->event = medion_kbd_event;
```

```c
static int medion_kbd_event(struct input_dev *dev, unsigned int type,
                             unsigned int code, int value) {
    ...
    leds = (scrolllock ? 0x01 : 0) | (numlock ? 0x02 : 0) | (capslock ? 0x04 : 0);
    serio_write(kbd->serio, 0xed);
    serio_write(kbd->serio, leds);
    return 0;
}
```

Turns out the EC does honor the standard SETLEDS command once something
actually sends it — the LED hardware was fine, nothing was ever asking
it to light up.

### Install

```bash
sudo bash keyboard/install.sh
```

Builds the module, signs it with a locally-generated MOK key if Secure
Boot is enabled (you'll need to enroll it on next reboot — the script
prints the exact steps), installs it + a systemd unit that binds it to
`serio0` on every boot, and adds the required `i8042` boot parameters.
Reboot afterwards.

## Bug 2: battery never reports "Charging"

### The bug

Plug the charger in, watch the battery percentage actually climb, and
`BAT0`'s `status` still says `Discharging`. Every desktop environment
that trusts the kernel's `POWER_SUPPLY_STATUS` (which is all of them)
never shows a charging icon.

### Diagnosis

`/sys/class/power_supply/ADP1/online` flips correctly. `BAT0/capacity`
and `energy_now` update correctly and promptly. Only `status` is wrong —
and it's wrong permanently, not just briefly stale. That rules out a
caching or notification problem and points straight at the ACPI method
that computes it.

Dumping and disassembling the DSDT (`iasl -d`) confirms it:

```asl
Method (_BST, 0, NotSerialized) // _BST: Battery Status
{
    ...
    PKG1 [Zero] = (B1ST & 0x07)   // <- blindly trusts the EC's raw byte
    ...
}
```

`_BST` just forwards the EC's `B1ST` register as the ACPI "battery
state" bits (bit 0 = discharging, bit 1 = charging). The EC never sets
the charging bit — a firmware bug, confirmed by the fact that AC
presence (`ECWR` bit 0, used correctly elsewhere by `ADP1._PSR`) and
charge percentage (`BPCN`) are both reported accurately by the same EC.

### The fix

[`battery-charging-fix/patch_bst.py`](battery-charging-fix/patch_bst.py)
rewrites `_BST` to derive the state from the two EC fields that *are*
trustworthy instead of the one that isn't:

```asl
PKG1 [Zero] = (B1ST & 0x07)
Local3 = (B1ST & 0x04)              /* keep the "critical" bit */
If ((ECWR & One))                   /* AC connected? */
{
    If ((BPCN < 0x64))              /* below 100%? */
    {
        PKG1 [Zero] = (0x02 | Local3)   /* -> Charging */
    }
    Else
    {
        PKG1 [Zero] = (Zero | Local3)   /* -> Full / not charging */
    }
}
Else
{
    PKG1 [Zero] = (One | Local3)        /* -> Discharging */
}
```

This is loaded at boot as an [ACPI table override via
initrd](https://docs.kernel.org/admin-guide/acpi/initrd_table_override.html) —
no BIOS flashing involved, the patched table only lives in RAM for that
boot.

### The gotcha that cost the most time

The very first attempt compiled cleanly, loaded without errors
(`ACPI: DSDT ACPI table found in initrd`) — and did *nothing*. The
kernel only treats an initrd-provided table as a real replacement if its
**OEM Revision is more recent** than the platform's; an unchanged
revision is silently ignored, with no error at any log level. Confirmed
by reading `/sys/firmware/acpi/tables/DSDT` back at runtime: it was
still byte-identical to the untouched original. `patch_bst.py` now
increments the OEM Revision automatically, and a successful boot shows:

```
ACPI: Table Upgrade: override [DSDT-MEDION-MEDIONAG]
ACPI: DSDT ... Physical table override, new table: ...
```

### Install

```bash
sudo bash battery-charging-fix/install.sh
```

This **never touches your default boot entry**. It builds a separate,
clearly-named GRUB entry (`MEDION 14 S1 OLED (battery charging fix)`) so
you can test it first:

1. Reboot, manually select that entry from the GRUB menu.
2. Plug the charger in and confirm:
   ```bash
   cat /sys/class/power_supply/BAT0/status   # should say "Charging"
   ```
3. Once confirmed, make it permanent:
   ```bash
   sudo bash battery-charging-fix/install.sh --make-default
   ```

## Safety

Both fixes are specific to the MEDION 14 S1 OLED / board `NM14RPL`. The
installers check `/sys/class/dmi/id/board_name` and refuse to run on a
different board unless you pass `--force`. Don't pass `--force` unless
you've independently confirmed the same underlying EC bug on your
machine.

- The **keyboard driver** is an out-of-tree, unsigned-by-default kernel
  module. If Secure Boot is enabled, the installer signs it with a
  locally-generated MOK key that you enroll yourself on reboot — nothing
  is sent anywhere.
- The **battery fix** replaces the DSDT — the ACPI table describing your
  entire system, not just the battery — for one specific boot entry.
  The installer never overwrites your original kernel, initrd, or
  default GRUB entry; the unmodified boot path is always one menu
  selection away. If something ever goes wrong, just reboot and pick the
  other entry.

## Uninstall

```bash
sudo bash keyboard/uninstall.sh
sudo bash battery-charging-fix/uninstall.sh
```

or via the interactive menu (`./install.sh`).

## Credits

- Base keyboard scancode driver: [mrelmida/medion-signium-keyboard](https://github.com/mrelmida/medion-signium-keyboard) (GPL-2.0)
- Caps Lock LED support, battery ACPI fix, and installers: this repo
- [`gum`](https://github.com/charmbracelet/gum) for the install menu

## License

GPL-2.0 — see [LICENSE](LICENSE).
