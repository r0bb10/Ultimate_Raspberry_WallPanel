# Wallpanel Setup

Turn a Raspberry Pi (or any Linux box) into a dedicated Home Assistant kiosk display. No desktop environment bloat, just a fullscreen browser that boots straight to your dashboard.

## What It Does

This script configures a minimal Wayland-based kiosk system:
- **labwc** compositor (lightweight, ~30MB RAM)
- **Chromium** in kiosk mode with performance optimizations
- **Greetd** for autologin
- **Kanshi** for display management
- Boots to your Home Assistant URL in ~15 seconds on a Pi 4

I built this because every "kiosk mode" tutorial involved installing a full desktop environment and then trying to lock it down. This approach starts minimal and stays minimal.

## Quick Start

```bash
sudo ./wallpanel_setup.sh
```

The script will walk you through configuration with a text-based menu. It saves your choices, so you can re-run it to adjust settings without starting over.

## Features

### Core Setup
- Interactive configuration wizard (no editing config files by hand)
- Custom resolution or auto-detect from EDID
- Screen rotation (portrait/landscape)
- Touchscreen support with automatic device detection
- Silent boot option (no kernel messages or boot logo)
- Scheduled reboots for long-term stability

### Extras Menu
- **Passwordless Sudo** - convenience for maintenance
- **Watchdog Timer** - auto-restart Chromium if it crashes
- **Display Sleep Schedule** - turn screen off/on at specific times
- **Brightness Control** - adjust backlight (DSI displays only)

### Performance Optimizations
- tmpfs cache (reduces SD card wear)
- Hardware video acceleration (Vaapi)
- GPU rasterization enabled
- Disabled sync, extensions, background processes
- Network optimization flags

## Requirements

**Tested on:**
- Raspberry Pi OS Bookworm (Debian 12)
- Raspberry Pi 4 & 5
- Official 7" touchscreen and various HDMI displays

**Should work on:**
- Any Debian/Ubuntu-based system with Wayland support
- Other SBCs (Orange Pi, etc.)

**Minimum:**
- 1GB RAM (2GB recommended)
- Any display with HDMI or DSI
- Network connectivity

## Installation

1. Flash Raspberry Pi OS Lite (64-bit recommended)
2. Complete initial setup (user account, network, etc.)
3. Download the script:
```bash
wget https://github.com/yourusername/wallpanel-setup/raw/main/wallpanel_setup.sh
chmod +x wallpanel_setup.sh
```
4. Run it:
```bash
sudo ./wallpanel_setup.sh
```
5. Follow the prompts
6. Reboot when finished

## Configuration Options

### Display Resolution
- **Auto** - Let the monitor decide (recommended)
- **Force** - Pick a specific resolution from detected modes or enter custom

The script reads available modes directly from your display, so you'll see what actually works.

### Touch Input
Filters out non-touch devices automatically (keyboards, GPIO, audio devices, etc.). If your touchscreen doesn't appear in the list, use the "Manual" option and check `/proc/bus/input/devices` for the exact device name.

### HDMI Hotplug
Enable "Always On" if your display doesn't report EDID properly or if you're using a cheap HDMI switch. This forces the Pi to output video even when it thinks nothing is connected.

## Advanced Usage

### Verbose Mode
See exactly what the script is doing:
```bash
sudo ./wallpanel_setup.sh -v
```

### Configuration File
Settings are saved to `.kiosk-config` in the same directory as the script. You can edit this file directly if you want to script installations:

```bash
saved_KIOSK_URL="http://homeassistant.local:8123"
saved_ROTATION="90"
saved_TOUCH_DEVICE="Your Touch Device Name"
# ... etc
```

### Manual Chromium Flags
Edit `~/.config/labwc/autostart` after installation to add custom Chromium flags. The script already includes 30+ optimization flags, but you might want to add things like `--force-device-scale-factor=1.25` for high-DPI displays.

## Troubleshooting

**Black screen after boot**
- Check HDMI cable (seriously, it's usually the cable)
- Try enabling "Always On" (Force HDMI Hotplug)
- Boot in verbose mode: remove `quiet` from `/boot/firmware/cmdline.txt`

**Touch not working**
- Re-run the script and check the touch device name carefully
- Compare against `grep 'Name=' /proc/bus/input/devices`
- Some USB touchscreens need time to initialize - try adding `sleep 5` before Chromium starts in the autostart file

**Chromium crashes**
- Enable the Watchdog in Extras menu
- Check `journalctl -u greetd` for errors
- Try disabling hardware acceleration by removing the Vaapi flags

**Network not ready at boot**
The script waits up to 10 seconds for network. If your network is slower:
```bash
nano ~/.config/labwc/autostart
# Change: timeout 10s bash -c '...'
# To:     timeout 30s bash -c '...'
```

## Uninstall

```bash
sudo ./wallpanel_setup.sh
# Select "Uninstall" from the menu
```

This removes all installed packages, config files, and reverts boot parameters. Your system will go back to console-only mode.

## Architecture Notes

### Why Wayland?
X11 is basically unmaintained at this point. Wayland compositors are lighter, more secure, and better supported on modern hardware.

### Why labwc?
It's the spiritual successor to Openbox but for Wayland. Minimal resource usage, XML config, good touch support. Perfect for a kiosk where you just need a window manager that stays out of the way.

### Why Greetd?
Because systemd autologin is a pain to configure correctly, and display managers like LightDM pull in tons of dependencies. Greetd is 200KB and does one thing well.

## Known Issues

- Brightness control only works on DSI displays (official Pi touchscreen, Waveshare, etc.)
- Some USB touchscreens report weird device names with special characters - use Manual entry if filtering fails
- On first boot, Chromium might show a "Restore Session" dialog - dismiss it once and it won't appear again

## Contributing

Found a bug? Have a feature idea? PRs welcome. 

This script started as a quick weekend project and grew into something people actually use. If you improve it, please share back so everyone benefits.

## License

MIT - do whatever you want with it.

## Credits

Built out of frustration with existing solutions. Inspired by everyone who's ever posted "just use X11 and Openbox" and then disappeared when someone asked how.

If this saves you time, consider buying me a coffee or contributing to the Home Assistant project.