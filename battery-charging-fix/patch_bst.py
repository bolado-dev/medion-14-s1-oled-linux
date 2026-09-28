#!/usr/bin/env python3
"""
Patches a freshly-disassembled DSDT (iasl -d dsdt.dat -> dsdt.dsl) for the
MEDION 14 S1 OLED (board NM14RPL) to fix a firmware bug where BAT0._BST
always reports "Discharging", even while genuinely charging on AC power.

Root cause: _BST blindly returns the EC's B1ST byte as the ACPI battery
"state" bits, and B1ST never sets the charging bit. AC presence (ECWR bit 0)
and charge percentage (BPCN) are both reported correctly elsewhere, so this
patch derives the state from those instead.

Also bumps the DSDT's OEM Revision by 1: the Linux kernel's initrd ACPI
table-override mechanism only replaces a table whose OEM Revision is MORE
RECENT than the platform's -- an unchanged revision is silently ignored
(detected in dmesg as "found in initrd" with no matching "Physical table
override" line).

Usage: patch_bst.py <path-to-dsdt.dsl>   (edits the file in place)
"""
import re
import sys

MARKER = "medion-14-s1-oled-linux: patched BAT0._BST state"

ORIGINAL_BLOCK_RE = re.compile(
    r"([ \t]*)PKG1 \[Zero\] = \(B1ST & 0x07\)\s*\n"
    r"([ \t]*)If \(\(B1ST & One\)\)"
)

DEFBLOCK_RE = re.compile(
    r'(DefinitionBlock \("[^"]*", "DSDT", \d+, "MEDION", "MEDIONAG", )'
    r"(0x[0-9A-Fa-f]+)(\))"
)


def patch(text: str) -> str:
    if MARKER in text:
        print("Already patched, nothing to do.")
        return text

    def bump_revision(m: re.Match) -> str:
        rev = int(m.group(2), 16) + 1
        return f"{m.group(1)}0x{rev:08X}{m.group(3)}"

    new_text, n = DEFBLOCK_RE.subn(bump_revision, text, count=1)
    if n != 1:
        sys.exit(
            "Could not find the DSDT DefinitionBlock header (MEDION/MEDIONAG).\n"
            "This script targets the MEDION 14 S1 OLED (board NM14RPL) firmware;\n"
            "it will not apply as-is to a different model."
        )
    text = new_text

    m = ORIGINAL_BLOCK_RE.search(text)
    if not m:
        sys.exit(
            "Could not find the original BAT0._BST state assignment.\n"
            "The firmware on this machine may differ from the one this patch\n"
            "was written against -- see README.md for the manual patch."
        )

    indent = m.group(1)
    patch_block = (
        f"{indent}PKG1 [Zero] = (B1ST & 0x07)\n"
        f"{indent}/* {MARKER} */\n"
        f"{indent}Local3 = (B1ST & 0x04)\n"
        f"{indent}If ((ECWR & One))\n"
        f"{indent}{{\n"
        f"{indent}    If ((BPCN < 0x64))\n"
        f"{indent}    {{\n"
        f"{indent}        PKG1 [Zero] = (0x02 | Local3)\n"
        f"{indent}    }}\n"
        f"{indent}    Else\n"
        f"{indent}    {{\n"
        f"{indent}        PKG1 [Zero] = (Zero | Local3)\n"
        f"{indent}    }}\n"
        f"{indent}}}\n"
        f"{indent}Else\n"
        f"{indent}{{\n"
        f"{indent}    PKG1 [Zero] = (One | Local3)\n"
        f"{indent}}}\n"
        f"\n"
        f"{m.group(2)}If ((B1ST & One))"
    )

    text = text[: m.start()] + patch_block + text[m.end() :]
    return text


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <path-to-dsdt.dsl>")

    path = sys.argv[1]
    with open(path, "r") as f:
        original = f.read()

    patched = patch(original)

    if patched == original:
        return

    with open(path, "w") as f:
        f.write(patched)

    print(f"Patched {path}: BAT0._BST state fix + OEM Revision bump applied.")


if __name__ == "__main__":
    main()
