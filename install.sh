#!/bin/bash
# Interactive installer for the MEDION 14 S1 OLED Linux fixes.
# Uses `gum` (https://github.com/charmbracelet/gum) for the menu when
# available, and falls back to a plain shell menu otherwise.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ensure_gum() {
    if command -v gum >/dev/null 2>&1; then
        return 0
    fi

    echo "This installer looks nicer with 'gum' (a small TUI tool), but it's optional."
    printf "Install gum now via apt? [y/N] "
    read -r reply
    case "$reply" in
        y|Y)
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
            echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
            sudo apt-get update -qq
            sudo apt-get install -y gum
            ;;
        *)
            return 1
            ;;
    esac
}

banner() {
    if command -v gum >/dev/null 2>&1; then
        gum style --border rounded --border-foreground 212 --padding "1 4" --margin "1 0" \
            "MEDION 14 S1 OLED — Linux fixes" \
            "$(gum style --foreground 245 'Custom serio keyboard driver + ACPI battery charging-state fix')"
    else
        echo "=============================================="
        echo " MEDION 14 S1 OLED — Linux fixes"
        echo " Custom serio keyboard driver + ACPI battery fix"
        echo "=============================================="
    fi
}

board_check() {
    local board
    board="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)"
    if [ "$board" != "NM14RPL" ]; then
        if command -v gum >/dev/null 2>&1; then
            gum style --foreground 214 "Warning: this board is '${board}', not the expected NM14RPL (MEDION 14 S1 OLED)."
            gum style --foreground 214 "These fixes are hardware-specific and may not apply to your machine."
        else
            echo "Warning: this board is '${board}', not the expected NM14RPL (MEDION 14 S1 OLED)."
            echo "These fixes are hardware-specific and may not apply to your machine."
        fi
    fi
}

choose() {
    local prompt="$1"; shift
    if command -v gum >/dev/null 2>&1; then
        gum choose --header "$prompt" "$@"
    else
        echo "$prompt"
        select opt in "$@"; do
            [ -n "$opt" ] && echo "$opt" && break
        done
    fi
}

confirm() {
    local prompt="$1"
    if command -v gum >/dev/null 2>&1; then
        gum confirm "$prompt"
    else
        printf "%s [y/N] " "$prompt"
        read -r reply
        [ "$reply" = "y" ] || [ "$reply" = "Y" ]
    fi
}

run_step() {
    local title="$1"; shift
    if command -v gum >/dev/null 2>&1; then
        gum spin --title "$title" -- "$@" || { "$@"; }
    else
        echo "==> $title"
        "$@"
    fi
}

clear
banner
board_check
ensure_gum || true
echo

CHOICE="$(choose "¿Qué quieres instalar?" \
    "Fix de teclado (scancodes + LED Bloq Mayús)" \
    "Fix de batería (icono de carga en la barra)" \
    "Instalar ambos" \
    "Desinstalar fix de teclado" \
    "Desinstalar fix de batería" \
    "Salir")"

case "$CHOICE" in
    "Fix de teclado"*)
        sudo bash "$DIR/keyboard/install.sh"
        ;;
    "Fix de batería"*)
        sudo bash "$DIR/battery-charging-fix/install.sh"
        if confirm "¿Ya probaste el arranque de prueba y funciona? ¿Hacerlo el arranque por defecto?"; then
            sudo bash "$DIR/battery-charging-fix/install.sh" --make-default
        fi
        ;;
    "Instalar ambos")
        sudo bash "$DIR/keyboard/install.sh"
        sudo bash "$DIR/battery-charging-fix/install.sh"
        echo
        echo "Reinicia y prueba primero la entrada de GRUB de batería manualmente."
        echo "Cuando confirmes que funciona, hazla por defecto con:"
        echo "  sudo bash $DIR/battery-charging-fix/install.sh --make-default"
        ;;
    "Desinstalar fix de teclado")
        sudo bash "$DIR/keyboard/uninstall.sh"
        ;;
    "Desinstalar fix de batería")
        sudo bash "$DIR/battery-charging-fix/uninstall.sh"
        ;;
    *)
        echo "Nada que hacer."
        exit 0
        ;;
esac
