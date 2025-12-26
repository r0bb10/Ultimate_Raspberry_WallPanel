#!/bin/bash

# ==============================================================================
# WALLPANEL SETUP SCRIPT v4.1
# ==============================================================================
# A complete kiosk system for running Home Assistant on dedicated displays
# Configures Wayland (labwc), Chromium browser, and system optimization
#
# CHANGELOG:
# v4.1 (Current)
#   - Backported production performance flags (Vaapi, GPU acceleration)
#   - Improved Greetd/autostart logic over production version
#   - Added Chrome sync/extension/update disabling for stability
#   - Network optimization with background networking disabled
#
# v4.0
#   - Migrated to Wayland (labwc compositor)
#   - Greetd autologin system
#   - Kanshi display management
#   - Touch device configuration support
#
# v3.x
#   - X11-based kiosk system
#   - Openbox window manager
#   - Basic chromium integration
# ==============================================================================

# ==============================================================================
# INITIALIZATION
# ==============================================================================

# Parse command line arguments for verbose mode
VERBOSE_MODE="no"
if [ "$1" == "-v" ]; then
    VERBOSE_MODE="yes"
    echo ">>> VERBOSE MODE ENABLED. Progress bars disabled."
    sleep 1
fi

# Determine script directory and configuration file location
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="$SCRIPT_DIR/.kiosk-config"
ERROR_LOG="/tmp/wallpanel_install_error.log"

# Verify script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./wallpanel_setup.sh)"
  exit 1
fi

# Identify the actual user (not root) who invoked sudo
REAL_USER=${SUDO_USER:-$(whoami)}
USER_HOME="/home/$REAL_USER"
USER_UID=$(id -u "$REAL_USER")

# Detect kernel command line location (varies by Raspberry Pi OS version)
if [ -f "/boot/firmware/cmdline.txt" ]; then
    CMDLINE="/boot/firmware/cmdline.txt"
elif [ -f "/boot/cmdline.txt" ]; then
    CMDLINE="/boot/cmdline.txt"
else
    # Create dummy file if neither exists (non-Pi systems)
    CMDLINE="/tmp/cmdline_dummy"
    touch "$CMDLINE"
fi

# Load previously saved configuration if it exists
if [ -f "$CONFIG_FILE" ]; then source "$CONFIG_FILE"; fi

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

# Whiptail wrapper for user input dialogs
ask() { whiptail --title "Wallpanel Setup" --inputbox "$1" 10 70 "$2" 3>&1 1>&2 2>&3; }

# Whiptail wrapper for message boxes
msg() { whiptail --title "Wallpanel Setup" --msgbox "$1" 10 70; }

# Retrieve current system hostname
CURRENT_HOSTNAME=$(cat /etc/hostname)

# Detect which display output is currently connected
# Scans DRM subsystem for connected displays, falls back to HDMI-A-1
detect_display_output() {
    for status_file in /sys/class/drm/card*-*/status; do
        if [ -f "$status_file" ] && grep -q "^connected$" "$status_file" 2>/dev/null; then
            echo "$status_file" | sed 's|.*/card[0-9]-||;s|/status||'
            return
        fi
    done
    echo "HDMI-A-1"
}
DISPLAY_OUTPUT=$(detect_display_output)

# Check if running on Raspberry Pi hardware
is_raspberry_pi() {
    [ -f /sys/firmware/devicetree/base/model ] && grep -qi "raspberry" /sys/firmware/devicetree/base/model 2>/dev/null
}

# Validate time format (HH:MM)
validate_time() {
    [[ "$1" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

# Validate URL format (basic check)
validate_url() {
    [[ "$1" =~ ^https?:// ]]
}

# Validate percentage input (0-100)
validate_percentage() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 0 ] && [ "$1" -le 100 ]
}

# ==============================================================================
# CMDLINE.TXT MANAGEMENT
# ==============================================================================
# Provides atomic operations on boot parameters to avoid corruption
# Uses temporary files and validation before committing changes

# Read current cmdline parameters into variable
read_cmdline() {
    cat "$CMDLINE" | tr '\n' ' '
}

# Write new cmdline parameters atomically
# Creates temporary file, validates, then moves into place
write_cmdline() {
    local new_content="$1"
    local temp_file="${CMDLINE}.tmp"
    
    echo -n "$new_content" > "$temp_file"
    
    # Validate the new file isn't empty and has reasonable content
    if [ -s "$temp_file" ] && [ $(wc -c < "$temp_file") -gt 10 ]; then
        mv "$temp_file" "$CMDLINE"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Remove specific parameter from cmdline
remove_cmdline_param() {
    local param_pattern="$1"
    local current=$(read_cmdline)
    local new_content=$(echo "$current" | sed "s/ ${param_pattern}[^ ]*//g")
    write_cmdline "$new_content"
}

# Add parameter to cmdline if not already present
add_cmdline_param() {
    local param="$1"
    local current=$(read_cmdline)
    
    # Check if parameter already exists
    if echo "$current" | grep -q "$param"; then
        return 0
    fi
    
    write_cmdline "${current} ${param}"
}

# ==============================================================================
# EXTRAS MENU
# ==============================================================================
# Provides optional features: passwordless sudo, watchdog, sleep schedule, brightness

do_extras() {
    # Define service file paths
    SUDOERS_FILE="/etc/sudoers.d/090_wallpanel_nopasswd"
    WATCHDOG_SERVICE="/etc/systemd/system/kiosk-watchdog.service"
    WATCHDOG_TIMER="/etc/systemd/system/kiosk-watchdog.timer"
    SLEEP_SERVICE="/etc/systemd/system/kiosk-display-sleep.service"
    SLEEP_ON_TIMER="/etc/systemd/system/kiosk-display-on.timer"
    SLEEP_OFF_TIMER="/etc/systemd/system/kiosk-display-off.timer"

    while true; do
        # Detect current status of each feature
        [ -f "$SUDOERS_FILE" ] && SUDO_STATUS="ENABLED" || SUDO_STATUS="DISABLED"
        systemctl is-enabled kiosk-watchdog.timer &>/dev/null && WATCHDOG_STATUS="ENABLED" || WATCHDOG_STATUS="DISABLED"
        systemctl is-enabled kiosk-display-on.timer &>/dev/null && SLEEP_STATUS="ENABLED" || SLEEP_STATUS="DISABLED"

        # Display extras menu with current status
        EXTRA_CHOICE=$(whiptail --title "Extras Menu" --menu "Select a feature:" 16 70 5 \
        "Sudoless" "Passwordless Sudo ($SUDO_STATUS)" \
        "Watchdog" "Auto-restart Chromium if crashed ($WATCHDOG_STATUS)" \
        "Sleep" "Display Sleep Schedule ($SLEEP_STATUS)" \
        "Brightness" "[EXPERIMENTAL] Adjust Screen Brightness" \
        "Back" "Return to Main Menu" 3>&1 1>&2 2>&3)

        if [ "$EXTRA_CHOICE" == "Back" ] || [ -z "$EXTRA_CHOICE" ]; then return; fi

        # Toggle passwordless sudo for the current user
        if [ "$EXTRA_CHOICE" == "Sudoless" ]; then
            if [ "$SUDO_STATUS" == "ENABLED" ]; then
                rm -f "$SUDOERS_FILE"
                msg "Passwordless Sudo has been DISABLED."
            else
                echo "$REAL_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
                chmod 0440 "$SUDOERS_FILE"
                msg "Passwordless Sudo has been ENABLED for user '$REAL_USER'."
            fi
        fi

        # Configure watchdog timer to restart Chromium if it crashes
        # Checks every 2 minutes if chromium process exists, restarts labwc if not
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
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
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
                msg "Watchdog has been ENABLED."
            fi
        fi

        # Configure scheduled display sleep (turn off/on at specific times)
        # Uses wlr-randr to control display power state via Wayland
        if [ "$EXTRA_CHOICE" == "Sleep" ]; then
            if [ "$SLEEP_STATUS" == "ENABLED" ]; then
                systemctl disable --now kiosk-display-on.timer kiosk-display-off.timer 2>/dev/null
                rm -f "$SLEEP_SERVICE" "$SLEEP_ON_TIMER" "$SLEEP_OFF_TIMER" \
                      "/etc/systemd/system/kiosk-display-sleep@.service" \
                      "/etc/systemd/system/kiosk-display-on.service" \
                      "/etc/systemd/system/kiosk-display-off.service"
                systemctl daemon-reload
                msg "Display Sleep Schedule has been DISABLED."
            else
                # Prompt user for sleep schedule times with validation
                SLEEP_OFF_TIME=$(ask "Enter time to turn display OFF (HH:MM):" "22:00")
                if ! validate_time "$SLEEP_OFF_TIME"; then
                    msg "Invalid time format. Use HH:MM (24-hour format)."
                    continue
                fi
                
                SLEEP_ON_TIME=$(ask "Enter time to turn display ON (HH:MM):" "07:00")
                if ! validate_time "$SLEEP_ON_TIME"; then
                    msg "Invalid time format. Use HH:MM (24-hour format)."
                    continue
                fi
                
                # Create systemd service template for display power control
                cat > "$SLEEP_SERVICE" <<EOF
[Unit]
Description=Kiosk Display Power Control
[Service]
Type=oneshot
User=$REAL_USER
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
ExecStart=/usr/bin/wlr-randr --output $DISPLAY_OUTPUT --%i
EOF
                # Create timer for turning display off
                cat > "$SLEEP_OFF_TIMER" <<EOF
[Unit]
Description=Turn display off at $SLEEP_OFF_TIME
[Timer]
OnCalendar=*-*-* ${SLEEP_OFF_TIME}:00
Persistent=false
[Install]
WantedBy=timers.target
EOF
                # Create timer for turning display on
                cat > "$SLEEP_ON_TIMER" <<EOF
[Unit]
Description=Turn display on at $SLEEP_ON_TIME
[Timer]
OnCalendar=*-*-* ${SLEEP_ON_TIME}:00
Persistent=false
[Install]
WantedBy=timers.target
EOF
                # Create concrete services for on/off actions
                ln -sf "$SLEEP_SERVICE" /etc/systemd/system/kiosk-display-sleep@.service
                cat > /etc/systemd/system/kiosk-display-off.service <<EOF
[Unit]
Description=Turn display off
[Service]
Type=oneshot
User=$REAL_USER
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
ExecStart=/usr/bin/wlr-randr --output $DISPLAY_OUTPUT --off
EOF
                cat > /etc/systemd/system/kiosk-display-on.service <<EOF
[Unit]
Description=Turn display on
[Service]
Type=oneshot
User=$REAL_USER
Environment=WAYLAND_DISPLAY=wayland-1
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
ExecStart=/usr/bin/wlr-randr --output $DISPLAY_OUTPUT --on
EOF
                systemctl daemon-reload
                systemctl enable --now kiosk-display-on.timer kiosk-display-off.timer
                msg "Display Sleep Schedule ENABLED."
            fi
        fi

        # Adjust screen brightness (DSI displays only, uses kernel backlight interface)
        if [ "$EXTRA_CHOICE" == "Brightness" ]; then
            BACKLIGHT_PATH=$(find /sys/class/backlight -maxdepth 1 -type l | head -n 1)
            if [ -z "$BACKLIGHT_PATH" ]; then
                msg "No backlight control detected. Only works with DSI displays."
            else
                MAX_BRIGHT=$(cat "$BACKLIGHT_PATH/max_brightness" 2>/dev/null || echo 255)
                CUR_BRIGHT=$(cat "$BACKLIGHT_PATH/brightness" 2>/dev/null || echo 128)
                CUR_PERCENT=$((CUR_BRIGHT * 100 / MAX_BRIGHT))
                NEW_PERCENT=$(ask "Set Brightness (0-100%):" "$CUR_PERCENT")
                
                if validate_percentage "$NEW_PERCENT"; then
                    NEW_BRIGHT=$((NEW_PERCENT * MAX_BRIGHT / 100))
                    echo "$NEW_BRIGHT" > "$BACKLIGHT_PATH/brightness"
                    msg "Brightness set to $NEW_PERCENT%"
                else
                    msg "Invalid percentage. Must be 0-100."
                fi
            fi
        fi
    done
}

# ==============================================================================
# UNINSTALL FUNCTION
# ==============================================================================
# Complete factory reset - removes all kiosk components and restores defaults

do_uninstall() {
    if ! (whiptail --title "Factory Reset" --yesno "WARNING: Full Factory Reset.\n\nProceed?" 20 60 --defaultno); then return; fi
    clear
    
    echo ">>> Purging packages..."
    DEBIAN_FRONTEND=noninteractive apt purge -y labwc greetd kanshi chromium chromium-browser wtype libinput-tools wlr-randr unattended-upgrades rpi-chromium-mods
    apt autoremove -y

    echo ">>> Removing config files..."
    rm -rf "$USER_HOME/.config/labwc" "$USER_HOME/.config/kanshi" "$USER_HOME/.config/chromium"
    rm -f /etc/greetd/config.toml /etc/systemd/system/greetd.service.d/override.conf "$CONFIG_FILE"
    rm -f "/etc/sudoers.d/090_wallpanel_nopasswd"
    
    # Disable and remove all kiosk-related systemd services
    systemctl disable --now kiosk-reboot.timer kiosk-watchdog.timer kiosk-display-on.timer kiosk-display-off.timer 2>/dev/null
    rm -f /etc/systemd/system/kiosk-*
    
    # Remove tmpfs mount for Chromium cache
    sed -i '/\/tmp\/chromium-cache/d' /etc/fstab
    rm -rf /tmp/chromium-cache

    echo ">>> Restoring Kernel parameters..."
    # Remove kiosk-specific boot parameters
    remove_cmdline_param "video=HDMI-A-1"
    remove_cmdline_param "quiet"
    remove_cmdline_param "splash"
    remove_cmdline_param "logo.nologo"
    remove_cmdline_param "vt.global_cursor_default=0"
    remove_cmdline_param "consoleblank=0"

    # Restore default system configuration
    systemctl disable NetworkManager-wait-online.service
    systemctl set-default multi-user.target
    systemctl daemon-reload
    
    echo -e "\033[1;32m>>> UNINSTALL COMPLETE. Reboot recommended.\033[0m"
    exit 0
}

# ==============================================================================
# MAIN MENU
# ==============================================================================
# Primary navigation interface for the setup script

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
# CONFIGURATION WIZARD
# ==============================================================================
# Interactive setup collecting all necessary configuration parameters

# Prompt for Home Assistant URL with validation
while true; do
    DEFAULT_URL=${saved_KIOSK_URL:-"http://homeassistant.local:8123"}
    KIOSK_URL=$(ask "Enter the Home Assistant URL:" "$DEFAULT_URL")
    if [ -z "$KIOSK_URL" ]; then exit 0; fi
    
    if validate_url "$KIOSK_URL"; then
        break
    else
        msg "Invalid URL format. Must start with http:// or https://"
    fi
done

# Display resolution strategy selection
DEFAULT_STRAT=${saved_STRATEGY:-"Auto"}
STRATEGY=$(whiptail --title "Resolution Setup" --menu "Resolution Strategy" 15 60 2 \
"Auto" "Use Monitor Preference (EDID)" \
"Force" "Manually select a specific resolution" --default-item "$DEFAULT_STRAT" 3>&1 1>&2 2>&3)
if [ -z "$STRATEGY" ]; then exit 0; fi

# Handle resolution selection based on strategy
if [ "$STRATEGY" == "Auto" ]; then
    MODE="preferred"
else
    # Read available modes from DRM subsystem for the connected display
    DRM_MODES=$(cat /sys/class/drm/card*-${DISPLAY_OUTPUT}/modes 2>/dev/null)
    MENU_ARGS=()
    
    # Build menu with detected resolutions
    if [ ! -z "$DRM_MODES" ]; then 
        while read -r line; do 
            MENU_ARGS+=("$line@60" "Detected")
        done <<< "$DRM_MODES"
    fi
    
    # Add common fallback options
    MENU_ARGS+=("1920x1080@60" "Standard 1080p")
    MENU_ARGS+=("Custom" "Manual Entry")
    
    DEFAULT_RES=${saved_MODE:-"1920x1080@60"}
    SEL_RES=$(whiptail --title "Select Resolution" --menu "Choose Resolution:" 20 70 10 "${MENU_ARGS[@]}" --default-item "$DEFAULT_RES" 3>&1 1>&2 2>&3)
    if [ -z "$SEL_RES" ]; then exit 0; fi
    
    if [ "$SEL_RES" == "Custom" ]; then 
        MODE=$(ask "Enter Custom Mode:" "$DEFAULT_RES")
    else 
        MODE="$SEL_RES"
    fi
fi

# Screen rotation/orientation selection
DEFAULT_ROT=${saved_ROTATION:-"0"}
ROTATION=$(whiptail --title "Screen Rotation" --menu "Select Orientation" 15 60 4 \
"0" "Landscape" "90" "Portrait" "180" "Inverted Landscape" "270" "Inverted Portrait" --default-item "$DEFAULT_ROT" 3>&1 1>&2 2>&3)
if [ -z "$ROTATION" ]; then exit 0; fi

# HDMI hotplug control (force signal even when display appears disconnected)
whiptail --title "Connection" --yesno "Enable 'Always On' (Force HDMI Hotplug)?" 15 60 --defaultno && FORCE_HDMI="yes" || FORCE_HDMI="no"

# Touch device configuration with intelligent filtering
TOUCH_DEVICE=""
if whiptail --title "Touch Input" --yesno "Do you want to configure a Touchscreen?" 10 60; then
    # Read all input devices from kernel
    mapfile -t DEV_LIST < <(grep 'N: Name=' /proc/bus/input/devices | sed 's/N: Name="//;s/"$//' | sort -u)
    TOUCH_MENU=()
    
    # Filter out non-touch devices (GPU, audio, buttons, etc.)
    # This reduces clutter and shows only devices likely to be touchscreens
    for dev in "${DEV_LIST[@]}"; do
        ldev=${dev,,}
        
        # Skip known non-touch device types
        if [[ "$ldev" == *"vc4"* ]] || [[ "$ldev" == *"hdmi"* ]] || \
           [[ "$ldev" == *"button"* ]] || [[ "$ldev" == *"gpio"* ]] || \
           [[ "$ldev" == *"audio"* ]] || [[ "$ldev" == *"headset"* ]] || \
           [[ "$ldev" == *"keyboard"* ]] || [[ "$ldev" == *"mouse"* ]] || \
           [[ "$ldev" == *"video"* ]] || [[ "$ldev" == *"camera"* ]]; then
           continue
        fi
        
        TOUCH_MENU+=("$dev" "Device")
    done
    
    TOUCH_MENU+=("Manual" "Type name manually")
    SEL_TOUCH=$(whiptail --title "Select Touch Device" --menu "Detected Devices:" 20 75 10 "${TOUCH_MENU[@]}" 3>&1 1>&2 2>&3)
    
    if [ "$SEL_TOUCH" == "Manual" ]; then 
        TOUCH_DEVICE=$(ask "Enter Exact Touch Device Name:" "")
    else 
        TOUCH_DEVICE="$SEL_TOUCH"
    fi
fi

# Silent boot configuration (hide kernel messages, boot logo, cursor)
whiptail --title "Boot" --yesno "Enable Silent Boot (Appliance Mode)?" 15 60 --defaultno && SILENT_BOOT="yes" || SILENT_BOOT="no"

# Scheduled reboot configuration for maintenance
DEFAULT_SCHED=${saved_REBOOT_SCHEDULE:-"Disabled"}
REBOOT_SCHEDULE=$(whiptail --title "Maintenance" --menu "Scheduled Reboot" 15 60 3 \
"Disabled" "Never" "Daily" "Daily" "Weekly" "Weekly" --default-item "$DEFAULT_SCHED" 3>&1 1>&2 2>&3)

if [ "$REBOOT_SCHEDULE" != "Disabled" ]; then
    while true; do
        REBOOT_TIME=$(ask "Enter Reboot Time (HH:MM):" "${saved_REBOOT_TIME:-03:00}")
        if validate_time "$REBOOT_TIME"; then
            break
        else
            msg "Invalid time format. Use HH:MM (24-hour format)."
        fi
    done
else
    REBOOT_TIME=""
fi

# System timezone configuration
TIMEZONE=$(ask "Enter Timezone:" "${saved_TIMEZONE:-Europe/Rome}")

# SSH server toggle
whiptail --title "SSH" --yesno "Enable SSH Server?" 10 60 --defaultno && ENABLE_SSH="yes" || ENABLE_SSH="no"

# Automatic security updates toggle
whiptail --title "Security" --yesno "Enable Unattended Upgrades?" 10 60 --defaultno && ENABLE_SECURITY="yes" || ENABLE_SECURITY="no"

# Save configuration for future runs
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
saved_ENABLE_SSH="$ENABLE_SSH"
saved_ENABLE_SECURITY="$ENABLE_SECURITY"
EOF
chmod 600 "$CONFIG_FILE"

# Confirm before applying changes
ACTION=$(whiptail --title "Configuration Saved" --menu "Action:" 15 60 2 "Apply" "Install" "Exit" "Save Only" 3>&1 1>&2 2>&3)
if [ "$ACTION" != "Apply" ]; then exit 0; fi

# ==============================================================================
# INSTALLATION PHASE
# ==============================================================================
# Applies configuration and installs all required packages and services

# Setup progress reporting based on verbose mode
if [ "$VERBOSE_MODE" == "yes" ]; then
    setup_progress() { clear; echo ">>> STARTING INSTALLATION (Verbose Mode)"; }
    update_progress() { echo -e "\n======================================================\n>>> $2\n======================================================"; }
    finish_progress() { echo ">>> DONE."; }
else
    # Use whiptail gauge for visual progress in normal mode
    setup_progress() { 
        clear
        PROGRESS_PIPE=$(mktemp -u)
        mkfifo "$PROGRESS_PIPE"
        whiptail --title "Installing Wallpanel" --gauge "Initializing..." 8 70 0 < "$PROGRESS_PIPE" &
        WHIPTAIL_PID=$!
        exec 3> "$PROGRESS_PIPE"
    }
    update_progress() { echo -e "XXX\n$1\n$2\nXXX" >&3; }
    finish_progress() { exec 3>&-; wait $WHIPTAIL_PID 2>/dev/null; rm -f "$PROGRESS_PIPE"; }
fi

setup_progress

# Update package lists
update_progress 0 "Updating package lists..."
export DEBIAN_FRONTEND=noninteractive
if [ "$VERBOSE_MODE" == "yes" ]; then 
    apt-get update
else 
    apt-get update -qq > "$ERROR_LOG" 2>&1
fi
update_progress 15 "Package lists updated."

# Determine correct Chromium package name (varies by distribution)
update_progress 16 "Determining packages..."
CHROMIUM_PKG="chromium"
if apt-cache policy chromium-browser | grep "Candidate:" | grep -v "(none)" > /dev/null; then 
    CHROMIUM_PKG="chromium-browser"
fi

# Add Raspberry Pi-specific optimizations if on Pi hardware
MODS_PKG=""
if is_raspberry_pi && apt-cache policy rpi-chromium-mods | grep "Candidate:" | grep -v "(none)" > /dev/null; then 
    MODS_PKG="rpi-chromium-mods"
fi

# Build package list based on configuration
PACKAGES="labwc greetd kanshi $CHROMIUM_PKG wtype libinput-tools wlr-randr $MODS_PKG"
[ "$ENABLE_SSH" == "yes" ] && PACKAGES="$PACKAGES openssh-server"
[ "$ENABLE_SECURITY" == "yes" ] && PACKAGES="$PACKAGES unattended-upgrades"

# Install all required packages
update_progress 20 "Installing packages: $CHROMIUM_PKG $MODS_PKG ..."
if [ "$VERBOSE_MODE" == "yes" ]; then
    apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $PACKAGES
    INSTALL_EXIT=$?
else
    if ! apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $PACKAGES > "$ERROR_LOG" 2>&1; then 
        INSTALL_EXIT=1
    else 
        INSTALL_EXIT=0
    fi
fi

# Handle installation failure
if [ $INSTALL_EXIT -ne 0 ]; then
    if [ "$VERBOSE_MODE" != "yes" ]; then exec 3>&-; kill $WHIPTAIL_PID 2>/dev/null; fi
    echo -e "\033[1;31mERROR: Package installation failed.\033[0m"
    if [ "$VERBOSE_MODE" != "yes" ]; then echo "Error Log:"; cat "$ERROR_LOG"; fi
    exit 1
fi
update_progress 50 "Packages installed."

# ==============================================================================
# SYSTEM CONFIGURATION
# ==============================================================================

update_progress 51 "Configuring system..."

# Set system timezone
[ ! -z "$TIMEZONE" ] && timedatectl set-timezone "$TIMEZONE"

# Configure SSH service
if [ "$ENABLE_SSH" == "yes" ]; then
    systemctl enable ssh >/dev/null 2>&1
    systemctl start ssh >/dev/null 2>&1
else
    systemctl disable ssh >/dev/null 2>&1
    systemctl stop ssh >/dev/null 2>&1
fi

# Configure scheduled reboot if enabled
if [ "$REBOOT_SCHEDULE" != "Disabled" ] && [ ! -z "$REBOOT_TIME" ]; then
    CALENDAR_STR="*-*-* ${REBOOT_TIME}:00"
    [ "$REBOOT_SCHEDULE" == "Weekly" ] && CALENDAR_STR="Mon *-*-* ${REBOOT_TIME}:00"
    
    # Create systemd service for reboot action
    cat > /etc/systemd/system/kiosk-reboot.service <<EOF
[Unit]
Description=Scheduled Kiosk Reboot
[Service]
Type=oneshot
ExecStart=/sbin/reboot
EOF
    # Create systemd timer to trigger the reboot
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
    systemctl enable --now kiosk-reboot.timer >/dev/null 2>&1
else
    systemctl disable --now kiosk-reboot.timer >/dev/null 2>&1
fi

# Force system to boot into graphical target (required for Wayland)
systemctl set-default graphical.target >/dev/null 2>&1
update_progress 65 "System configured."

# ==============================================================================
# KERNEL BOOT PARAMETERS
# ==============================================================================
# Configure boot parameters for display, silent boot, and HDMI behavior

update_progress 66 "Configuring kernel..."

# Remove any existing video parameters to start clean
remove_cmdline_param "video=HDMI-A-1"
remove_cmdline_param "quiet"
remove_cmdline_param "splash"
remove_cmdline_param "logo.nologo"
remove_cmdline_param "vt.global_cursor_default=0"
remove_cmdline_param "consoleblank=0"

# Build video parameter based on resolution and hotplug settings
# Format: video=HDMI-A-1:1920x1080@60D (D=force enabled)
KERNEL_VID_ARG=""
if [ "$FORCE_HDMI" == "yes" ]; then
    [ "$MODE" == "preferred" ] && KERNEL_VID_ARG="video=HDMI-A-1:D" || KERNEL_VID_ARG="video=HDMI-A-1:${MODE}D"
elif [ "$MODE" != "preferred" ]; then
    KERNEL_VID_ARG="video=HDMI-A-1:${MODE}"
fi

# Build silent boot parameters if enabled
SILENT_ARGS=""
if [ "$SILENT_BOOT" == "yes" ]; then
    SILENT_ARGS="quiet splash logo.nologo vt.global_cursor_default=0 consoleblank=0"
fi

# Apply all boot parameters
[ -n "$KERNEL_VID_ARG" ] && add_cmdline_param "$KERNEL_VID_ARG"
if [ -n "$SILENT_ARGS" ]; then
    for arg in $SILENT_ARGS; do
        add_cmdline_param "$arg"
    done
fi

update_progress 75 "Kernel configured."

# ==============================================================================
# NETWORK OPTIMIZATION
# ==============================================================================
# Reload systemd to pick up any network-related changes

update_progress 76 "Configuring network..."
systemctl daemon-reload
update_progress 85 "Network configured."

# ==============================================================================
# WAYLAND COMPOSITOR & BROWSER CONFIGURATION
# ==============================================================================
# Configure labwc (Wayland compositor), kanshi (display manager), and Chromium

update_progress 86 "Configuring Labwc & Chromium..."

# Configure kanshi for display output management
# Kanshi applies display settings (resolution, rotation) at compositor startup
mkdir -p "$USER_HOME/.config/kanshi"
KANSHI_TRANSFORM="$ROTATION"
[ "$ROTATION" == "0" ] && KANSHI_TRANSFORM="normal"
cat > "$USER_HOME/.config/kanshi/config" <<EOF
profile {
    output $DISPLAY_OUTPUT mode $MODE transform $KANSHI_TRANSFORM
}
EOF

# Configure labwc compositor
# labwc is a lightweight Wayland compositor similar to Openbox
mkdir -p "$USER_HOME/.config/labwc"
cat > "$USER_HOME/.config/labwc/rc.xml" <<EOF
<?xml version="1.0"?>
<labwc_config>
EOF

# Add touch device mapping if configured
# Maps touch input to specific display output (multi-monitor support)
if [ ! -z "$TOUCH_DEVICE" ]; then
    echo "  <touch deviceName=\"$TOUCH_DEVICE\" mapToOutput=\"$DISPLAY_OUTPUT\"/>" >> "$USER_HOME/.config/labwc/rc.xml"
fi

# Add keyboard shortcuts and cursor hiding
cat >> "$USER_HOME/.config/labwc/rc.xml" <<EOF
  <keyboard>
    <keybind key="W-q"><action name="Exit"/></keybind>
    <keybind key="W-h">
      <action name="HideCursor"/>
      <action name="WarpCursor" to="output" x="1" y="1"/>
    </keybind>
  </keyboard>
</labwc_config>
EOF

# Setup tmpfs cache for Chromium (RAM-based cache for speed and flash wear reduction)
CACHE_DIR="/tmp/chromium-cache"
if ! grep -q "/tmp/chromium-cache" /etc/fstab; then
    echo "tmpfs /tmp/chromium-cache tmpfs nodev,nosuid,size=100M 0 0" >> /etc/fstab
fi
mkdir -p /tmp/chromium-cache
mount /tmp/chromium-cache 2>/dev/null || true

# Create labwc autostart script
# This launches all required services when labwc starts
cat > "$USER_HOME/.config/labwc/autostart" <<EOF
#!/bin/bash

# Start kanshi for display management
kanshi &

# Trigger native cursor hiding (Win+H keybind)
sleep 1 && wtype -M logo -k h -m logo &

# Wait for network connectivity before launching browser
# Timeout after 10 seconds to prevent indefinite hang
timeout 10s bash -c 'until ping -c1 google.com &>/dev/null; do sleep 1; done'

# Launch Chromium in kiosk mode with extensive optimizations
/usr/bin/chromium \\
    --autoplay-policy=no-user-gesture-required \\
    --kiosk "$KIOSK_URL" \\
    --start-fullscreen --start-maximized --fast --fast-start \\
    --no-sandbox --no-first-run --noerrdialogs \\
    --disable-translate --disable-notifications --disable-infobars --disable-pinch \\
    --disable-features=TranslateUI --disk-cache-dir=$CACHE_DIR \\
    --ozone-platform=wayland \\
    --enable-features=OverlayScrollbar,CanvasOopRasterization,VaapiVideoDecoder \\
    --overscroll-history-navigation=0 --password-store=basic --force-dark-mode \\
    --restore-last-session --disable-session-crashed-bubble \\
    --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy \\
    --disable-background-networking --disable-sync --disable-default-apps \\
    --disable-extensions --disable-component-update --disable-background-timer-throttling \\
    --disable-renderer-backgrounding --disable-backgrounding-occluded-windows &
EOF
chmod +x "$USER_HOME/.config/labwc/autostart"

# Configure greetd for automatic login
# greetd is a minimal display manager that auto-starts labwc as the user
mkdir -p /etc/greetd
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

# Configure automatic security updates if enabled
if [ "$ENABLE_SECURITY" == "yes" ]; then
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
else
    rm -f /etc/apt/apt.conf.d/20auto-upgrades
fi

# Set proper ownership for all user configuration files
chown -R "$REAL_USER:$REAL_USER" "$USER_HOME/.config"

update_progress 100 "Installation complete!"
finish_progress

# Display completion message
if [ "$VERBOSE_MODE" == "yes" ]; then
    echo ">>> INSTALLATION COMPLETE. Please reboot to apply changes."
else
    msg "Installation Complete!\n\nPlease reboot your system to apply changes."
fi

exit 0