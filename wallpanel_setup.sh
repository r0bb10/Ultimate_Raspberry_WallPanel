#!/bin/bash

# ==============================================================================
# WALLPANEL SETUP (v3.0)
# ==============================================================================
# Features:
# - Install/Update with Wizard
# - State Management (.kiosk-config)
# - Silent Boot / "Appliance Mode"
# - Scheduled Reboots (Systemd Timers)
# - Extras Menu (Passwordless Sudo)
# - Full Revert/Uninstall capability
# ==============================================================================

# --- LOCATE CONFIG FILE ---
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/.kiosk-config"

# --- Check Root ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./wallpanel_setup.sh)"
  exit
fi

# --- Get Real User ---
REAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME="/home/$REAL_USER"

# --- Load Previous Config (If exists) ---
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# --- Whiptail Helper Functions ---
ask() { whiptail --title "Wallpanel Setup" --inputbox "$1" 10 70 "$2" 3>&1 1>&2 2>&3; }
msg() { whiptail --title "Wallpanel Setup" --msgbox "$1" 10 70; }

# --- Detection Helpers ---
if [ -z "$saved_TOUCH_DEVICE" ]; then
    DETECTED_TOUCH=$(grep -i 'Name=".*Touch.*"' /proc/bus/input/devices | head -n 1 | sed 's/N: Name="//; s/"$//')
else
    DETECTED_TOUCH="$saved_TOUCH_DEVICE"
fi
CURRENT_HOSTNAME=$(cat /etc/hostname)

# ==============================================================================
# FUNCTION: EXTRAS MENU
# ==============================================================================
do_extras() {
    SUDOERS_FILE="/etc/sudoers.d/090_wallpanel_nopasswd"

    while true; do
        # Check current state
        if [ -f "$SUDOERS_FILE" ]; then
            SUDO_STATUS="ENABLED"
        else
            SUDO_STATUS="DISABLED"
        fi

        EXTRA_CHOICE=$(whiptail --title "Extras Menu" --menu "Select a feature to toggle:" 15 65 3 \
        "Sudoless" "Passwordless Sudo (Current: $SUDO_STATUS)" \
        "Back" "Return to Main Menu" 3>&1 1>&2 2>&3)

        if [ "$EXTRA_CHOICE" == "Back" ] || [ -z "$EXTRA_CHOICE" ]; then return; fi

        if [ "$EXTRA_CHOICE" == "Sudoless" ]; then
            if [ "$SUDO_STATUS" == "ENABLED" ]; then
                rm -f "$SUDOERS_FILE"
                msg "Passwordless Sudo has been DISABLED.\nYou will now be prompted for a password when using sudo."
            else
                echo "$REAL_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
                chmod 0440 "$SUDOERS_FILE"
                msg "Passwordless Sudo has been ENABLED for user '$REAL_USER'.\n\nBe careful, this reduces security."
            fi
        fi
    done
}

# ==============================================================================
# FUNCTION: UNINSTALL / REVERT
# ==============================================================================
do_uninstall() {
    WARN_MSG="WARNING: This will perform a full factory reset of the Kiosk system.\n\nActions:\n1. Purge Labwc, Kanshi, Chromium, Greetd.\n2. Delete all config files.\n3. Restore Kernel (Verbose boot, HDMI defaults).\n4. Remove scheduled reboot timers.\n5. Remove Passwordless Sudo config.\n\nNOTE: SSH Server will NOT be removed to prevent lockout.\n\nAre you sure?"
    
    if ! (whiptail --title "Factory Reset" --yesno "$WARN_MSG" 20 60 --defaultno); then
        return
    fi

    clear
    echo -e "\033[1;31m>>> STARTING UNINSTALL...\033[0m"

    # 1. Remove Packages (EXCLUDING openssh-server for safety)
    echo ">>> Purging packages..."
    PACKAGES="labwc greetd kanshi chromium-browser rpi-chromium-mods wtype libinput-tools unattended-upgrades"
    DEBIAN_FRONTEND=noninteractive apt purge -y $PACKAGES
    apt autoremove -y

    # 2. Clean Configs
    echo ">>> Removing config files..."
    rm -rf "$USER_HOME/.config/labwc"
    rm -rf "$USER_HOME/.config/kanshi"
    rm -rf "$USER_HOME/.config/chromium"
    rm -f /etc/greetd/config.toml
    rm -f /etc/systemd/system/greetd.service.d/override.conf
    rm -f /etc/apt/apt.conf.d/20auto-upgrades
    rm -f "$CONFIG_FILE"
    
    # Remove Extras
    rm -f "/etc/sudoers.d/090_wallpanel_nopasswd"
    
    # Remove Systemd Reboot Timers
    systemctl disable --now kiosk-reboot.timer 2>/dev/null
    rm -f /etc/systemd/system/kiosk-reboot.service
    rm -f /etc/systemd/system/kiosk-reboot.timer
    
    rmdir /etc/systemd/system/greetd.service.d 2>/dev/null

    # 3. Restore Kernel (Cmdline)
    echo ">>> Restoring Kernel parameters..."
    CMDLINE="/boot/firmware/cmdline.txt"
    # Remove HDMI hacks
    sed -i 's/ video=HDMI-A-1[^ ]*//g' "$CMDLINE"
    # Remove Silent Boot hacks
    sed -i 's/ quiet//g; s/ splash//g; s/ logo.nologo//g; s/ vt.global_cursor_default=0//g; s/ consoleblank=0//g' "$CMDLINE"

    # 4. Restore Services
    echo ">>> Disabling services..."
    systemctl disable NetworkManager-wait-online.service
    systemctl daemon-reload

    echo -e "\033[1;32m>>> UNINSTALL COMPLETE.\033[0m"
    msg "System reverted to clean state.\nSSH access has been retained.\n\nA reboot is recommended."
    exit 0
}

# ==============================================================================
# MAIN MENU
# ==============================================================================
while true; do
    MAIN_CHOICE=$(whiptail --title "Wallpanel Setup" --menu "Select an option:" 16 60 4 \
    "Install" "Configure and Install Wallpanel" \
    "Extras" "Additional Tools (Sudoless, etc)" \
    "Uninstall" "Remove Wallpanel and Revert to Stock" \
    "Exit" "Quit" 3>&1 1>&2 2>&3)

    if [ "$MAIN_CHOICE" == "Exit" ] || [ -z "$MAIN_CHOICE" ]; then exit 0; fi
    if [ "$MAIN_CHOICE" == "Uninstall" ]; then do_uninstall; exit 0; fi
    if [ "$MAIN_CHOICE" == "Extras" ]; then do_extras; continue; fi
    if [ "$MAIN_CHOICE" == "Install" ]; then break; fi
done

# ==============================================================================
# PHASE 1: THE WIZARD (Install Flow)
# ==============================================================================

# 1. URL
DEFAULT_URL=${saved_KIOSK_URL:-"http://homeassistant.local:8123"}
KIOSK_URL=$(ask "Enter the Home Assistant URL:" "$DEFAULT_URL")
if [ -z "$KIOSK_URL" ]; then exit 0; fi

# 2. Resolution Strategy
DEFAULT_STRAT=${saved_STRATEGY:-"Auto"}
STRATEGY=$(whiptail --title "Resolution Setup" --menu "Resolution Strategy" 15 60 2 \
"Auto" "Use Monitor Preference (EDID)" \
"Force" "Manually select a specific resolution" \
--default-item "$DEFAULT_STRAT" 3>&1 1>&2 2>&3)

if [ -z "$STRATEGY" ]; then exit 0; fi

if [ "$STRATEGY" == "Auto" ]; then
    MODE="preferred"
else
    # Propose resolutions logic
    DRM_MODES=$(find /sys/class/drm -name "card*-HDMI-A-1" -exec cat {}/modes 2>/dev/null \;)
    MENU_ARGS=()
    if [ ! -z "$DRM_MODES" ]; then
        while read -r line; do MENU_ARGS+=("$line@60" "Detected"); done <<< "$DRM_MODES"
    fi
    MENU_ARGS+=("1920x1080@60" "Standard 1080p")
    MENU_ARGS+=("1280x800@60"  "Official 10\"")
    MENU_ARGS+=("1024x600@60"  "Generic 7\"")
    MENU_ARGS+=("800x480@60"   "Official 7\"")
    MENU_ARGS+=("Custom"       "Manual Entry")

    DEFAULT_RES=${saved_MODE:-"1920x1080@60"}
    SEL_RES=$(whiptail --title "Select Resolution" --menu "Choose Resolution:" 20 70 10 "${MENU_ARGS[@]}" --default-item "$DEFAULT_RES" 3>&1 1>&2 2>&3)
    if [ -z "$SEL_RES" ]; then exit 0; fi
    
    if [ "$SEL_RES" == "Custom" ]; then
        MODE=$(ask "Enter Custom Mode (e.g. 1920x1080@60):" "$DEFAULT_RES")
    else
        MODE="$SEL_RES"
    fi
fi

# 3. Orientation
DEFAULT_ROT=${saved_ROTATION:-"0"}
ROTATION=$(whiptail --title "Screen Rotation" --menu "Select Orientation" 15 60 4 \
"0"   "Landscape (0°)" \
"90"  "Portrait (90°)" \
"180" "Inverted Landscape (180°)" \
"270" "Inverted Portrait (270°)" \
--default-item "$DEFAULT_ROT" 3>&1 1>&2 2>&3)
if [ -z "$ROTATION" ]; then exit 0; fi

# 4. Always On
if [ "$saved_FORCE_HDMI" == "no" ]; then DEFAULT_HDMI="--defaultno"; else DEFAULT_HDMI=""; fi
if (whiptail --title "Connection Stability" --yesno "Enable 'Always On' (Force HDMI Hotplug)?" 15 60 $DEFAULT_HDMI); then
    FORCE_HDMI="yes"
else
    FORCE_HDMI="no"
fi

# 5. Touch
TOUCH_DEVICE=$(ask "Enter Touch Device Name (Empty to skip):" "$DETECTED_TOUCH")

# 6. Silent Boot
if [ "$saved_SILENT_BOOT" == "yes" ]; then DEFAULT_SILENT="--defaultyes"; else DEFAULT_SILENT="--defaultno"; fi
if (whiptail --title "Boot Aesthetics" --yesno "Enable Silent Boot (Appliance Mode)?\n\n- Hides scrolling text/logos.\n- Hides console cursor.\n- Prevents screen from blanking (sleep)." 15 60 $DEFAULT_SILENT); then
    SILENT_BOOT="yes"
else
    SILENT_BOOT="no"
fi

# 7. Scheduled Reboot
DEFAULT_SCHED=${saved_REBOOT_SCHEDULE:-"Disabled"}
REBOOT_SCHEDULE=$(whiptail --title "Maintenance" --menu "Scheduled Reboot" 15 60 3 \
"Disabled" "Never auto-reboot" \
"Daily" "Reboot every day" \
"Weekly" "Reboot every Monday" \
--default-item "$DEFAULT_SCHED" 3>&1 1>&2 2>&3)

if [ "$REBOOT_SCHEDULE" != "Disabled" ]; then
    DEFAULT_TIME=${saved_REBOOT_TIME:-"03:00"}
    REBOOT_TIME=$(ask "Enter Reboot Time (24h format HH:MM):" "$DEFAULT_TIME")
else
    REBOOT_TIME=""
fi

# 8. Timezone
DEFAULT_TZ=${saved_TIMEZONE:-"Europe/Rome"}
TIMEZONE=$(ask "Enter Timezone (Required for Reboot Schedule):" "$DEFAULT_TZ")

# 9. Hostname
NEW_HOSTNAME=$(ask "Enter Hostname:" "${saved_HOSTNAME:-$CURRENT_HOSTNAME}")

# 10. SSH
if [ "$saved_ENABLE_SSH" == "no" ]; then DEFAULT_SSH="--defaultno"; else DEFAULT_SSH=""; fi
if (whiptail --title "Remote Access" --yesno "Enable SSH Server?" 10 60 $DEFAULT_SSH); then
    ENABLE_SSH="yes"
else
    ENABLE_SSH="no"
fi

# 11. Security
if [ "$saved_ENABLE_SECURITY" == "no" ]; then DEFAULT_SEC="--defaultno"; else DEFAULT_SEC=""; fi
if (whiptail --title "Security" --yesno "Enable Unattended Upgrades?" 10 60 $DEFAULT_SEC); then
    ENABLE_SECURITY="yes"
else
    ENABLE_SECURITY="no"
fi

# --- SAVE STATE ---
cat > "$CONFIG_FILE" <<EOF
saved_KIOSK_URL="$KIOSK_URL"
saved_STRATEGY="$STRATEGY"
saved_MODE="$MODE"
saved_ROTATION="$ROTATION"
saved_FORCE_HDMI="$FORCE_HDMI"
saved_TOUCH_DEVICE="$TOUCH_DEVICE"
saved_SILENT_BOOT="$SILENT_BOOT"
saved_REBOOT_SCHEDULE="$REBOOT_SCHEDULE"
saved_REBOOT_TIME="$REBOOT_TIME"
saved_TIMEZONE="$TIMEZONE"
saved_HOSTNAME="$NEW_HOSTNAME"
saved_ENABLE_SSH="$ENABLE_SSH"
saved_ENABLE_SECURITY="$ENABLE_SECURITY"
EOF
chmod 600 "$CONFIG_FILE"

# ==============================================================================
# PHASE 2: ACTION SELECTION
# ==============================================================================

ACTION=$(whiptail --title "Configuration Saved" --menu "What would you like to do?" 15 60 2 \
"Apply" "Install Packages, Apply Config & Reboot" \
"Exit" "Save Config Only (Do not install)" 3>&1 1>&2 2>&3)

if [ "$ACTION" != "Apply" ]; then
    msg "Configuration saved to $CONFIG_FILE.\n\nRun this script again when you are ready to apply."
    exit 0
fi

# ==============================================================================
# PHASE 3: INSTALLATION
# ==============================================================================
clear
echo -e "\033[1;34m>>> [1/5] Checking Packages...\033[0m"
PACKAGES="labwc greetd kanshi chromium-browser rpi-chromium-mods wtype libinput-tools"
[ "$ENABLE_SECURITY" == "yes" ] && PACKAGES="$PACKAGES unattended-upgrades"
[ "$ENABLE_SSH" == "yes" ] && PACKAGES="$PACKAGES openssh-server"
DEBIAN_FRONTEND=noninteractive apt install -y $PACKAGES

# ==============================================================================
# PHASE 4: CONFIGURATION APPLICATION
# ==============================================================================

echo -e "\033[1;34m>>> [2/5] System Access & Maintenance...\033[0m"
# Hostname
if [ ! -z "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*$CURRENT_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
fi

# Timezone
if [ ! -z "$TIMEZONE" ]; then
    timedatectl set-timezone "$TIMEZONE"
fi

# SSH
if [ "$ENABLE_SSH" == "yes" ]; then
    systemctl enable ssh; systemctl start ssh
else
    systemctl disable ssh; systemctl stop ssh
fi

# Scheduled Reboot (Systemd Timer)
if [ "$REBOOT_SCHEDULE" != "Disabled" ] && [ ! -z "$REBOOT_TIME" ]; then
    CALENDAR_STR="*-*-* ${REBOOT_TIME}:00"
    if [ "$REBOOT_SCHEDULE" == "Weekly" ]; then
        CALENDAR_STR="Mon *-*-* ${REBOOT_TIME}:00"
    fi

    cat > /etc/systemd/system/kiosk-reboot.service <<EOF
[Unit]
Description=Scheduled Kiosk Reboot
[Service]
Type=oneshot
ExecStart=/sbin/reboot
EOF

    cat > /etc/systemd/system/kiosk-reboot.timer <<EOF
[Unit]
Description=Schedule reboot ($REBOOT_SCHEDULE at $REBOOT_TIME)
[Timer]
OnCalendar=$CALENDAR_STR
Persistent=false
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now kiosk-reboot.timer
else
    systemctl disable --now kiosk-reboot.timer 2>/dev/null
    rm -f /etc/systemd/system/kiosk-reboot.service
    rm -f /etc/systemd/system/kiosk-reboot.timer
    systemctl daemon-reload
fi

echo -e "\033[1;34m>>> [3/5] Kernel Configuration...\033[0m"
CMDLINE="/boot/firmware/cmdline.txt"

# 1. CLEANUP
sed -i 's/ video=HDMI-A-1[^ ]*//g' "$CMDLINE"
sed -i 's/ quiet//g; s/ splash//g; s/ logo.nologo//g; s/ vt.global_cursor_default=0//g; s/ consoleblank=0//g' "$CMDLINE"

# 2. CALCULATE ARGS
KERNEL_VID_ARG=""
if [ "$FORCE_HDMI" == "yes" ]; then
    [ "$MODE" == "preferred" ] && KERNEL_VID_ARG="video=HDMI-A-1:D" || KERNEL_VID_ARG="video=HDMI-A-1:${MODE}D"
elif [ "$MODE" != "preferred" ]; then
    KERNEL_VID_ARG="video=HDMI-A-1:${MODE}"
fi

SILENT_ARGS=""
if [ "$SILENT_BOOT" == "yes" ]; then
    SILENT_ARGS="quiet splash logo.nologo vt.global_cursor_default=0 consoleblank=0"
fi

# 3. APPLY
if [ ! -z "$KERNEL_VID_ARG" ] || [ ! -z "$SILENT_ARGS" ]; then
    sed -i "s/$/ $KERNEL_VID_ARG $SILENT_ARGS/" "$CMDLINE"
    echo "Kernel updated: $KERNEL_VID_ARG $SILENT_ARGS"
fi

echo -e "\033[1;34m>>> [4/5] Network Wait...\033[0m"
systemctl enable NetworkManager-wait-online.service
mkdir -p /etc/systemd/system/greetd.service.d
cat > /etc/systemd/system/greetd.service.d/override.conf <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
EOF
systemctl daemon-reload

echo -e "\033[1;34m>>> [5/5] Wayland Config...\033[0m"

# Kanshi
mkdir -p "$USER_HOME/.config/kanshi"
cat > "$USER_HOME/.config/kanshi/config" <<EOF
profile {
    output HDMI-A-1 mode $MODE transform $ROTATION
}
EOF

# Labwc
mkdir -p "$USER_HOME/.config/labwc"
cat > "$USER_HOME/.config/labwc/rc.xml" <<EOF
<?xml version="1.0"?>
<labwc_config>
EOF
if [ ! -z "$TOUCH_DEVICE" ]; then
    echo "  <touch deviceName=\"$TOUCH_DEVICE\" mapToOutput=\"HDMI-A-1\"/>" >> "$USER_HOME/.config/labwc/rc.xml"
fi
cat >> "$USER_HOME/.config/labwc/rc.xml" <<EOF
  <keyboard>
    <keybind key="W-q"><action name="Exit"/></keybind>
    <keybind key="W-h"><action name="HideCursor"/></keybind>
  </keyboard>
</labwc_config>
EOF

# Autostart
cat > "$USER_HOME/.config/labwc/autostart" <<EOF
#!/bin/bash
kanshi &
sleep 1 && wtype -M logo -k h -m logo &
# Crash bubble fix
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/Default/Preferences 2>/dev/null
sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences 2>/dev/null
sleep 2
/usr/bin/chromium \\
    --autoplay-policy=no-user-gesture-required \\
    --kiosk "$KIOSK_URL" \\
    --start-fullscreen --start-maximized --fast --fast-start \\
    --no-sandbox --no-first-run --noerrdialogs \\
    --disable-translate --disable-notifications --disable-infobars --disable-pinch \\
    --disable-features=TranslateUI --disk-cache-dir=/dev/null \\
    --ozone-platform=wayland \\
    --enable-features=OverlayScrollbar,CanvasOopRasterization \\
    --overscroll-history-navigation=0 --password-store=basic --force-dark-mode \\
    --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy &
EOF
chmod +x "$USER_HOME/.config/labwc/autostart"

# Greetd
cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1
[default_session]
command = "labwc"
user = "$REAL_USER"
[initial_session]
command = "labwc"
user = "$REAL_USER"
EOF

# Security
if [ "$ENABLE_SECURITY" == "yes" ]; then
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
else
    rm -f /etc/apt/apt.conf.d/20auto-upgrades
fi

chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.config"

msg "Installation Complete!\n\nRebooting is required to apply changes."
reboot