# Ultimate Raspberry WallPanel

A comprehensive setup script for transforming a Raspberry Pi or other ARM single-board computer into a dedicated wall-mounted kiosk or dashboard panel, optimized for Home Assistant but compatible with any web-based interface.

## Overview

This script automates the complete configuration of a Raspberry Pi (or compatible SBC running Armbian/Debian) as a dedicated kiosk device. It uses modern Wayland-based components (Labwc, Kanshi, Greetd) for a lightweight and reliable display system. Display outputs are auto-detected for cross-platform compatibility.

## Features

- **Interactive Setup Wizard** - Menu-driven configuration using whiptail dialogs
- **State Management** - Saves configuration for easy updates and re-runs
- **Resolution Control** - Auto-detect or manually specify display resolution
- **Screen Rotation** - Support for 0, 90, 180, and 270 degree orientations
- **Touch Screen Support** - Automatic detection and mapping of touch input devices
- **Silent Boot Mode** - Appliance-like boot experience with no scrolling text or logos
- **HDMI Hotplug** - Force HDMI connection for displays that may disconnect
- **Scheduled Reboots** - Daily or weekly automatic reboots via systemd timers
- **SSH Access** - Optional SSH server for remote management
- **Unattended Upgrades** - Optional automatic security updates
- **Complete Uninstall** - Full revert capability to restore stock configuration

## Requirements

- Raspberry Pi 4/5 or other ARM SBC (Orange Pi, Rock Pi, etc.)
- Raspberry Pi OS Lite (64-bit), Armbian, or Debian-based distribution
- HDMI or other display output
- Network connection (Ethernet or WiFi)
- SSH access (for headless setup)

## Installation

1. Clone this repository or download the script:

```bash
git clone https://github.com/r0bb10/Ultimate_Raspberry_WallPanel.git
cd Ultimate_Raspberry_WallPanel
```

2. Make the script executable:

```bash
chmod +x wallpanel_setup.sh
```

3. Run the setup wizard as root:

```bash
sudo ./wallpanel_setup.sh
```

4. Follow the interactive prompts to configure your panel.

## Configuration Options

### URL
The web address to display in kiosk mode. Default: `http://homeassistant.local:8123`

### Resolution Strategy
- **Auto** - Uses the monitor's preferred resolution (EDID)
- **Force** - Manually select from detected modes or common presets

### Screen Rotation
- 0 degrees (Landscape)
- 90 degrees (Portrait)
- 180 degrees (Inverted Landscape)
- 270 degrees (Inverted Portrait)

### Always On (HDMI Hotplug)
Forces HDMI output even when no display is detected. Useful for displays that may temporarily disconnect.

### Touch Device
Enter the name of your touchscreen device for proper input mapping. The script attempts to auto-detect this.

### Silent Boot
Enables "appliance mode" which:
- Hides boot messages and logos
- Disables console cursor
- Prevents screen blanking/sleep

### Scheduled Reboot
- **Disabled** - No automatic reboots
- **Daily** - Reboot every day at specified time
- **Weekly** - Reboot every Monday at specified time

### Hostname
Set a custom hostname for the device.

### SSH Server
Enable or disable SSH for remote access.

### Unattended Upgrades
Enable automatic security updates.

## Menu Options

### Install
Runs the configuration wizard and applies all settings.

### Extras
Additional tools including:
- **Passwordless Sudo** - Enable/disable sudo without password prompts (reduces security)
- **Watchdog** - Automatically restart the session if Chromium crashes (checks every 2 minutes)
- **Display Sleep Schedule** - Turn display off at night and back on in the morning to save power
- **Brightness** - [EXPERIMENTAL] Adjust screen brightness (only works with DSI displays or DDC/CI compatible monitors)

### Uninstall
Performs a complete factory reset:
- Removes all installed packages (except SSH)
- Deletes configuration files
- Restores kernel parameters
- Removes scheduled reboot timers
- Removes watchdog and display sleep timers
- Removes Chromium tmpfs cache mount
- Retains SSH access to prevent lockout

## File Locations

| File | Purpose |
|------|---------|
| `.kiosk-config` | Saved configuration (same directory as script) |
| `~/.config/labwc/` | Window manager configuration |
| `~/.config/kanshi/` | Display/resolution configuration |
| `/etc/greetd/config.toml` | Login manager configuration |
| `/boot/firmware/cmdline.txt` | Kernel boot parameters |

## Components Used

- **Labwc** - Lightweight Wayland compositor
- **Kanshi** - Dynamic display configuration
- **Greetd** - Minimal login manager
- **Chromium** - Web browser in kiosk mode
- **wtype** - Wayland keyboard input automation
- **wlr-randr** - Wayland output management (for display sleep)

## Keyboard Shortcuts

When the kiosk is running:

| Shortcut | Action |
|----------|--------|
| Super + Q | Exit Labwc (return to login) |
| Super + H | Hide cursor |

## Troubleshooting

### Display not showing
- Try enabling "Always On" (HDMI Hotplug) option
- Check resolution settings match your display capabilities

### Touch not working
- Verify touch device name in `/proc/bus/input/devices`
- Re-run setup with correct touch device name

### Chromium crash on boot
The script includes automatic crash recovery that clears Chromium's crash flags on each boot.

### Need to access terminal
SSH into the device, or use the Super+Q shortcut to exit the compositor.

## Security Notes

- The `--no-sandbox` flag is used for Chromium, which is acceptable for a dedicated kiosk but reduces browser security
- Passwordless sudo (Extras menu) should only be enabled if you understand the security implications
- SSH access is retained during uninstall to prevent lockout on headless systems

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome. Please open an issue or submit a pull request.

## Acknowledgments

- Raspberry Pi Foundation for the hardware and OS
- The Wayland, Labwc, and Greetd projects for the display stack
- The Home Assistant community for inspiration
