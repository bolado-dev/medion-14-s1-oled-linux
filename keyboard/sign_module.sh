#!/bin/bash
# Signs medion_kbd.ko with a locally-generated MOK key, for systems that
# enforce UEFI Secure Boot (unsigned out-of-tree modules are otherwise
# refused by the kernel). Not needed if Secure Boot is disabled.
set -e

cd "$(dirname "$0")"

if [ ! -f medion_kbd.ko ]; then
    echo "medion_kbd.ko not found. Run 'make' first." >&2
    exit 1
fi

# 1. Locate sign-file (path differs between distros)
SIGN_FILE=""
for candidate in \
    "/lib/modules/$(uname -r)/build/scripts/sign-file" \
    "/usr/src/kernels/$(uname -r)/scripts/sign-file" \
    "/usr/src/linux-headers-$(uname -r)/scripts/sign-file"
do
    if [ -x "$candidate" ]; then
        SIGN_FILE="$candidate"
        break
    fi
done

if [ -z "$SIGN_FILE" ]; then
    echo "Could not find 'sign-file'. Install your kernel headers package." >&2
    exit 1
fi

# 2. Generate MOK key pair if not exists
if [ ! -f MOK.priv ] || [ ! -f MOK.der ]; then
    echo "Generating MOK key pair..."
    openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER -out MOK.der -nodes -days 36500 -subj "/CN=Medion Keyboard MOK/"
fi

# 3. Sign the module
echo "Signing medion_kbd.ko with $SIGN_FILE ..."
sudo "$SIGN_FILE" sha256 MOK.priv MOK.der medion_kbd.ko

# 4. Enroll the key if not already enrolled or queued
if sudo mokutil --test-key MOK.der 2>&1 | grep -q "is enrolled"; then
    echo "MOK key is already enrolled."
else
    echo "Registering MOK key with mokutil..."
    echo -e "123456\n123456" | sudo mokutil --import MOK.der
    echo "MOK registration completed. Password set to: 123456"
    echo "IMPORTANT: You must reboot now."
    echo "On reboot, the blue MOK Manager screen will appear."
    echo "Choose: Enroll MOK -> Continue -> Yes -> Enter password '123456' -> Reboot."
fi
