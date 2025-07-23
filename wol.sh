g#!/usr/bin/env bash

# Wake-on-LAN auto-enabler with inline ArrowKeysMenu
# Author: ChatGPT + ArrowKeysMenu integration

set -euo pipefail

# Prompt for sudo if not root
if [[ $EUID -ne 0 ]]; then
    echo "This script needs root privileges. Prompting for sudo..."
    exec sudo "$0" "$@"
fi

# Check dependencies
command -v ethtool >/dev/null || {
    echo "Installing ethtool..."
    pacman -Sy --noconfirm ethtool
}

### -------- Embedded ArrowKeysMenu Function (simplified) --------
arrow_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local selected=0
    local ESC=$(printf "\033")
    local cursor_up=$(printf "${ESC}[A")
    local cursor_down=$(printf "${ESC}[B")
    local clear_line=$(printf "${ESC}[2K")
    local nl=$'\n'

    # Turn off cursor
    tput civis

    while true; do
        echo -e "$prompt"
        for i in "${!options[@]}"; do
            if [[ $i -eq $selected ]]; then
                echo -e "  \e[1;32m> ${options[$i]}\e[0m"
            else
                echo -e "    ${options[$i]}"
            fi
        done

        # Read arrow key
        IFS= read -rsn1 key
        [[ $key == $'\x1b' ]] && read -rsn2 key  # get full arrow key

        case "$key" in
            '[A') # up
                ((selected--))
                ((selected < 0)) && selected=$((${#options[@]} - 1))
                ;;
            '[B') # down
                ((selected++))
                ((selected >= ${#options[@]})) && selected=0
                ;;
            '') # enter
                break
                ;;
        esac

        # Clear menu
        for ((i=0; i<=${#options[@]}; i++)); do echo -ne "$clear_line\r\033[1A"; done
    done

    # Turn on cursor
    tput cnorm

    echo "${options[$selected]}"
}

### -------- Main Logic --------

# Get WoL-capable interfaces
get_wol_capable_ifaces() {
    for iface in $(ls /sys/class/net); do
        [[ "$iface" == "lo" ]] && continue
        wol_support=$(ethtool "$iface" 2>/dev/null | grep "Supports Wake-on" | awk '{print $3}')
        if [[ "$wol_support" != "d" && -n "$wol_support" ]]; then
            echo "$iface"
        fi
    done
}

interfaces=($(get_wol_capable_ifaces))

if [[ ${#interfaces[@]} -eq 0 ]]; then
    echo "❌ No network interfaces with Wake-on-LAN capability found."
    exit 1
elif [[ ${#interfaces[@]} -eq 1 ]]; then
    selected_iface="${interfaces[0]}"
    echo "✅ Only one WoL-capable interface detected: $selected_iface"
else
    selected_iface=$(arrow_menu "Multiple WoL-capable interfaces found. Select one:" "${interfaces[@]}")
    echo -e "\n✅ Selected: $selected_iface"
fi

# Show and enable WoL
echo
echo "🔍 Current WoL setting:"
ethtool "$selected_iface" | grep "Wake-on"

echo "🔧 Enabling WoL (MagicPacket) on $selected_iface..."
ethtool -s "$selected_iface" wol g

# Confirm
echo "✅ WoL enabled:"
ethtool "$selected_iface" | grep "Wake-on"

# Setup systemd service
service_path="/etc/systemd/system/wol@${selected_iface}.service"
echo "⚙️ Creating persistent systemd service..."

cat <<EOF > "$service_path"
[Unit]
Description=Enable Wake-on-LAN on ${selected_iface}
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ethtool -s ${selected_iface} wol g

[Install]
WantedBy=multi-user.target
EOF

systemctl enable wol@"$selected_iface".service

echo "🎉 Done! Wake-on-LAN is enabled and will persist across reboots."

