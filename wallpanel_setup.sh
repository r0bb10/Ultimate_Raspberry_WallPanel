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
  exit 1
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

# Detect connected display output (works on any SBC)
detect_display_output() {
    # Try to find a connected display from DRM subsystem
    for status_file in /sys/class/drm/card*-*/status; do
        if [ -f "$status_file" ] && grep -q "^connected$" "$status_file" 2>/dev/null; then
            # Extract output name (e.g., HDMI-A-1, DP-1, DSI-1)
            echo "$status_file" | sed 's|.*/card[0-9]-||;s|/status||'
            return
        fi
    done
    # Fallback to HDMI-A-1 if detection fails
    echo "HDMI-A-1"
}
DISPLAY_OUTPUT=$(detect_display_output)

# Detect if running on Raspberry Pi
is_raspberry_pi() {
    [ -f /sys/firmware/devicetree/base/model ] && grep -qi "raspberry" /sys/firmware/devicetree/base/model 2>/dev/null
}

# ==============================================================================
# FUNCTION: EXTRAS MENU
# ==============================================================================
do_extras() {
    SUDOERS_FILE="/etc/sudoers.d/090_wallpanel_nopasswd"
    WATCHDOG_SERVICE="/etc/systemd/system/kiosk-watchdog.service"
    WATCHDOG_TIMER="/etc/systemd/system/kiosk-watchdog.timer"
    SLEEP_SERVICE="/etc/systemd/system/kiosk-display-sleep.service"
    SLEEP_ON_TIMER="/etc/systemd/system/kiosk-display-on.timer"
    SLEEP_OFF_TIMER="/etc/systemd/system/kiosk-display-off.timer"

    while true; do
        # Check current states
        [ -f "$SUDOERS_FILE" ] && SUDO_STATUS="ENABLED" || SUDO_STATUS="DISABLED"
        systemctl is-enabled kiosk-watchdog.timer &>/dev/null && WATCHDOG_STATUS="ENABLED" || WATCHDOG_STATUS="DISABLED"
        systemctl is-enabled kiosk-display-on.timer &>/dev/null && SLEEP_STATUS="ENABLED" || SLEEP_STATUS="DISABLED"

        EXTRA_CHOICE=$(whiptail --title "Extras Menu" --menu "Select a feature:" 16 70 5 \
        "Sudoless" "Passwordless Sudo ($SUDO_STATUS)" \
        "Watchdog" "Auto-restart Chromium if crashed ($WATCHDOG_STATUS)" \
        "Sleep" "Display Sleep Schedule ($SLEEP_STATUS)" \
        "Brightness" "[EXPERIMENTAL] Adjust Screen Brightness" \
        "Back" "Return to Main Menu" 3>&1 1>&2 2>&3)

        if [ "$EXTRA_CHOICE" == "Back" ] || [ -z "$EXTRA_CHOICE" ]; then return; fi

        # --- Passwordless Sudo ---
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

        # --- Watchdog ---
        if [ "$EXTRA_CHOICE" == "Watchdog" ]; then
            if [ "$WATCHDOG_STATUS" == "ENABLED" ]; then
                systemctl disable --now kiosk-watchdog.timer 2>/dev/null
                rm -f "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
                systemctl daemon-reload
                msg "Watchdog has been DISABLED."
            else
                cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=Kiosk Chromium Watchdog
[Service]
Type=oneshot
User=$REAL_USER
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-1
ExecStart=/bin/bash -c 'pgrep -x chromium || (systemctl --user restart labwc || loginctl terminate-user $REAL_USER)'
EOF

                cat > "$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Run Kiosk Watchdog every 2 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF
                systemctl daemon-reload
                systemctl enable --now kiosk-watchdog.timer
                msg "Watchdog has been ENABLED.\n\nChromium will be monitored every 2 minutes and the session restarted if it crashes."
            fi
        fi

        # --- Display Sleep Schedule ---
        if [ "$EXTRA_CHOICE" == "Sleep" ]; then
            if [ "$SLEEP_STATUS" == "ENABLED" ]; then
                systemctl disable --now kiosk-display-on.timer kiosk-display-off.timer 2>/dev/null
                rm -f "$SLEEP_SERVICE" "$SLEEP_ON_TIMER" "$SLEEP_OFF_TIMER"
                systemctl daemon-reload
                msg "Display Sleep Schedule has been DISABLED."
            else
                SLEEP_OFF_TIME=$(ask "Enter time to turn display OFF (HH:MM):" "22:00")
                SLEEP_ON_TIME=$(ask "Enter time to turn display ON (HH:MM):" "07:00")
                
                # Validate times
                if ! [[ "$SLEEP_OFF_TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    msg "Invalid OFF time. Using default 22:00"
                    SLEEP_OFF_TIME="22:00"
                fi
                if ! [[ "$SLEEP_ON_TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                    msg "Invalid ON time. Using default 07:00"
                    SLEEP_ON_TIME="07:00"
                fi

                cat > "$SLEEP_SERVICE" <<EOF
[Unit]
Description=Kiosk Display Power Control
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo %i > /sys/class/backlight/*/bl_power 2>/dev/null || wlr-randr --output $DISPLAY_OUTPUT --%i'
EOF

                cat > "$SLEEP_OFF_TIMER" <<EOF
[Unit]
Description=Turn display off at $SLEEP_OFF_TIME
[Timer]
OnCalendar=*-*-* ${SLEEP_OFF_TIME}:00
Persistent=false
[Install]
WantedBy=timers.target
EOF

                cat > "$SLEEP_ON_TIMER" <<EOF
[Unit]
Description=Turn display on at $SLEEP_ON_TIME
[Timer]
OnCalendar=*-*-* ${SLEEP_ON_TIME}:00
Persistent=false
[Install]
WantedBy=timers.target
EOF

                # Create instantiated service links
                ln -sf "$SLEEP_SERVICE" /etc/systemd/system/kiosk-display-sleep@.service
                cat > /etc/systemd/system/kiosk-display-off.service <<EOF
[Unit]
Description=Turn display off
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 1 > /sys/class/backlight/*/bl_power 2>/dev/null; wlr-randr --output $DISPLAY_OUTPUT --off 2>/dev/null || true'
EOF
                cat > /etc/systemd/system/kiosk-display-on.service <<EOF
[Unit]
Description=Turn display on
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo 0 > /sys/class/backlight/*/bl_power 2>/dev/null; wlr-randr --output $DISPLAY_OUTPUT --on 2>/dev/null || true'
EOF

                systemctl daemon-reload
                systemctl enable --now kiosk-display-on.timer kiosk-display-off.timer
                msg "Display Sleep Schedule ENABLED.\n\nDisplay OFF: $SLEEP_OFF_TIME\nDisplay ON: $SLEEP_ON_TIME"
            fi
        fi

        # --- Brightness (Experimental) ---
        if [ "$EXTRA_CHOICE" == "Brightness" ]; then
            # Try to find backlight
            BACKLIGHT_PATH=$(find /sys/class/backlight -maxdepth 1 -type l | head -n 1)
            
            if [ -z "$BACKLIGHT_PATH" ]; then
                msg "[EXPERIMENTAL]\n\nNo backlight control detected.\n\nThis feature only works with DSI displays or displays with DDC/CI support."
            else
                MAX_BRIGHT=$(cat "$BACKLIGHT_PATH/max_brightness" 2>/dev/null || echo 255)
                CUR_BRIGHT=$(cat "$BACKLIGHT_PATH/brightness" 2>/dev/null || echo 128)
                CUR_PERCENT=$((CUR_BRIGHT * 100 / MAX_BRIGHT))
                
                NEW_PERCENT=$(ask "[EXPERIMENTAL] Set Brightness (0-100%):" "$CUR_PERCENT")
                if [[ "$NEW_PERCENT" =~ ^[0-9]+$ ]] && [ "$NEW_PERCENT" -ge 0 ] && [ "$NEW_PERCENT" -le 100 ]; then
                    NEW_BRIGHT=$((NEW_PERCENT * MAX_BRIGHT / 100))
                    echo "$NEW_BRIGHT" > "$BACKLIGHT_PATH/brightness"
                    msg "Brightness set to $NEW_PERCENT%\n\nNote: This change is temporary and will reset on reboot."
                else
                    msg "Invalid value. Please enter a number between 0 and 100."
                fi
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
    PACKAGES="labwc greetd kanshi chromium-browser wtype libinput-tools wlr-randr unattended-upgrades"
    is_raspberry_pi && PACKAGES="$PACKAGES rpi-chromium-mods"
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
    
    # Remove Watchdog
    systemctl disable --now kiosk-watchdog.timer 2>/dev/null
    rm -f /etc/systemd/system/kiosk-watchdog.service
    rm -f /etc/systemd/system/kiosk-watchdog.timer
    
    # Remove Display Sleep Timers
    systemctl disable --now kiosk-display-on.timer kiosk-display-off.timer 2>/dev/null
    rm -f /etc/systemd/system/kiosk-display-sleep.service
    rm -f /etc/systemd/system/kiosk-display-sleep@.service
    rm -f /etc/systemd/system/kiosk-display-on.service
    rm -f /etc/systemd/system/kiosk-display-off.service
    rm -f /etc/systemd/system/kiosk-display-on.timer
    rm -f /etc/systemd/system/kiosk-display-off.timer
    
    # Remove Chromium tmpfs cache mount
    sed -i '/\/tmp\/chromium-cache/d' /etc/fstab
    rm -rf /tmp/chromium-cache
    
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
    # Propose resolutions logic - use detected display output
    DRM_MODES=$(cat /sys/class/drm/card*-${DISPLAY_OUTPUT}/modes 2>/dev/null)
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
if [ "$saved_FORCE_HDMI" == "yes" ]; then
    whiptail --title "Connection Stability" --yesno "Enable 'Always On' (Force HDMI Hotplug)?" 15 60
else
    whiptail --title "Connection Stability" --yesno "Enable 'Always On' (Force HDMI Hotplug)?" 15 60 --defaultno
fi
if [ $? -eq 0 ]; then
    FORCE_HDMI="yes"
else
    FORCE_HDMI="no"
fi

# 5. Touch
TOUCH_DEVICE=$(ask "Enter Touch Device Name (Empty to skip):" "$DETECTED_TOUCH")

# 6. Silent Boot
if [ "$saved_SILENT_BOOT" == "yes" ]; then
    whiptail --title "Boot Aesthetics" --yesno "Enable Silent Boot (Appliance Mode)?\n\n- Hides scrolling text/logos.\n- Hides console cursor.\n- Prevents screen from blanking (sleep)." 15 60
else
    whiptail --title "Boot Aesthetics" --yesno "Enable Silent Boot (Appliance Mode)?\n\n- Hides scrolling text/logos.\n- Hides console cursor.\n- Prevents screen from blanking (sleep)." 15 60 --defaultno
fi
if [ $? -eq 0 ]; then
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
    # Validate time format
    if ! [[ "$REBOOT_TIME" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        msg "Invalid time format. Using default 03:00"
        REBOOT_TIME="03:00"
    fi
else
    REBOOT_TIME=""
fi

# 8. Timezone
DEFAULT_TZ=${saved_TIMEZONE:-"Europe/Rome"}
TIMEZONE=$(ask "Enter Timezone (Required for Reboot Schedule):" "$DEFAULT_TZ")
# Validate timezone
if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    msg "Invalid timezone '$TIMEZONE'. Using default Europe/Rome"
    TIMEZONE="Europe/Rome"
fi

# 9. Hostname
NEW_HOSTNAME=$(ask "Enter Hostname:" "${saved_HOSTNAME:-$CURRENT_HOSTNAME}")

# 10. SSH
if [ "$saved_ENABLE_SSH" == "yes" ]; then
    whiptail --title "Remote Access" --yesno "Enable SSH Server?" 10 60
else
    whiptail --title "Remote Access" --yesno "Enable SSH Server?" 10 60 --defaultno
fi
if [ $? -eq 0 ]; then
    ENABLE_SSH="yes"
else
    ENABLE_SSH="no"
fi

# 11. Security
if [ "$saved_ENABLE_SECURITY" == "yes" ]; then
    whiptail --title "Security" --yesno "Enable Unattended Upgrades?" 10 60
else
    whiptail --title "Security" --yesno "Enable Unattended Upgrades?" 10 60 --defaultno
fi
if [ $? -eq 0 ]; then
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
# PHASE 3: INSTALLATION (with progress bar)
# ==============================================================================

# Progress bar helper
PROGRESS_PIPE=$(mktemp -u)
mkfifo "$PROGRESS_PIPE"

show_progress() {
    whiptail --title "Installing Wallpanel" --gauge "Starting installation..." 8 70 0 < "$PROGRESS_PIPE" &
    PROGRESS_PID=$!
}

update_progress() {
    echo -e "XXX\n$1\n$2\nXXX" > "$PROGRESS_PIPE"
}

finish_progress() {
    echo "100" > "$PROGRESS_PIPE"
    wait $PROGRESS_PID 2>/dev/null
    rm -f "$PROGRESS_PIPE"
}

clear
show_progress

# Step 1: Update package lists (0-15%)
update_progress 0 "Updating package lists..."
apt update -qq > /dev/null 2>&1
update_progress 15 "Package lists updated."

# Step 2: Install packages (15-50%)
update_progress 16 "Installing packages..."
PACKAGES="labwc greetd kanshi chromium-browser wtype libinput-tools wlr-randr"
is_raspberry_pi && PACKAGES="$PACKAGES rpi-chromium-mods"
[ "$ENABLE_SECURITY" == "yes" ] && PACKAGES="$PACKAGES unattended-upgrades"
[ "$ENABLE_SSH" == "yes" ] && PACKAGES="$PACKAGES openssh-server"
DEBIAN_FRONTEND=noninteractive apt install -y -qq $PACKAGES > /dev/null 2>&1
update_progress 50 "Packages installed."

# ==============================================================================
# PHASE 4: CONFIGURATION APPLICATION
# ==============================================================================

# Step 3: System configuration (50-65%)
update_progress 51 "Configuring system..."

# Hostname
if [ -n "$NEW_HOSTNAME" ] && [ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    # Escape special regex characters in hostname
    ESCAPED_HOSTNAME=$(printf '%s\n' "$CURRENT_HOSTNAME" | sed 's/[.[\/^$*]/\\&/g')
    sed -i "s/127.0.1.1.*$ESCAPED_HOSTNAME/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
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

update_progress 65 "System configured."

# Step 4: Kernel configuration (65-75%)
update_progress 66 "Configuring kernel parameters..."
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
KERNEL_APPEND=""
[ -n "$KERNEL_VID_ARG" ] && KERNEL_APPEND="$KERNEL_VID_ARG"
[ -n "$SILENT_ARGS" ] && KERNEL_APPEND="${KERNEL_APPEND:+$KERNEL_APPEND }$SILENT_ARGS"
if [ -n "$KERNEL_APPEND" ]; then
    sed -i "s/$/ $KERNEL_APPEND/" "$CMDLINE"
fi

update_progress 75 "Kernel configured."

# Step 5: Network configuration (75-85%)
update_progress 76 "Configuring network wait..."
systemctl enable NetworkManager-wait-online.service > /dev/null 2>&1
mkdir -p /etc/systemd/system/greetd.service.d
cat > /etc/systemd/system/greetd.service.d/override.conf <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
EOF
systemctl daemon-reload

update_progress 85 "Network configured."

# Step 6: Wayland configuration (85-100%)
update_progress 86 "Configuring Wayland and Chromium..."

# Kanshi
mkdir -p "$USER_HOME/.config/kanshi"
# Convert rotation to Kanshi transform value (0 = normal)
KANSHI_TRANSFORM="$ROTATION"
[ "$ROTATION" == "0" ] && KANSHI_TRANSFORM="normal"
cat > "$USER_HOME/.config/kanshi/config" <<EOF
profile {
    output $DISPLAY_OUTPUT mode $MODE transform $KANSHI_TRANSFORM
}
EOF

# Labwc
mkdir -p "$USER_HOME/.config/labwc"
cat > "$USER_HOME/.config/labwc/rc.xml" <<EOF
<?xml version="1.0"?>
<labwc_config>
EOF
if [ ! -z "$TOUCH_DEVICE" ]; then
    echo "  <touch deviceName=\"$TOUCH_DEVICE\" mapToOutput=\"$DISPLAY_OUTPUT\"/>" >> "$USER_HOME/.config/labwc/rc.xml"
fi
cat >> "$USER_HOME/.config/labwc/rc.xml" <<EOF
  <keyboard>
    <keybind key="W-q"><action name="Exit"/></keybind>
    <keybind key="W-h"><action name="HideCursor"/></keybind>
  </keyboard>
</labwc_config>
EOF

# Autostart
# Setup tmpfs cache for Chromium (better performance, preserves SD card)
CACHE_DIR="/tmp/chromium-cache"
if ! grep -q "/tmp/chromium-cache" /etc/fstab; then
    echo "tmpfs /tmp/chromium-cache tmpfs nodev,nosuid,size=100M 0 0" >> /etc/fstab
fi
mkdir -p /tmp/chromium-cache
mount /tmp/chromium-cache 2>/dev/null || true

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
    --disable-features=TranslateUI --disk-cache-dir=$CACHE_DIR \\
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

update_progress 100 "Installation complete!"
finish_progress

msg "Installation Complete!\n\nRebooting is required to apply changes."
reboot