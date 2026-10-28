# mac-tv-display-fix

## Why this exists

A new **InnoView 23.8" 4K portable monitor** would not show a picture on a MacBook Pro. With a working video cable it woke up and had a signal, but the screen stayed black and macOS never listed it as a display, over HDMI or USB-C. Restarts, replugging, and the obvious display settings changed nothing. The cause turned out to be macOS 15 treating the monitor as a TV, then saving that blank state and reapplying it on every connection. It took a long session of reading system logs and display settings files to find. This script and README record the fix so the next person with this monitor, or any monitor macOS mistakes for a TV, can fix it in minutes.

The monitor:

| | |
|---|---|
| Brand | InnoView |
| Model (label on the monitor) | **INCPM608** |
| Model (user manual) | US-PM608-01B |
| Product | InnoView 23.8" 4K Large Portable Monitor, 3840×2160, 60Hz, IPS, USB-C + HDMI, speakers, 180° stand (Amazon ASIN B0DKT69JYB) |
| How it identifies itself to the Mac (EDID) | name "InnoView", manufacturer code YCT, vendor ID 0x6474, product ID 0x5AA4, made in 2025 |

The Mac: MacBook Pro 14" (M1 Pro, MacBookPro18,3) running macOS 15.7.3. Fixed on 2026-10-27.

## Symptoms

- The monitor wakes up and has a signal (no "No Signal" message), but the screen is black.
- System Settings → Displays and `system_profiler SPDisplaysDataType` show only the laptop screen.
- The monitor doesn't appear in Control Center → Screen Mirroring.
- Restarting and replugging don't help. Neither does changing "When connected to TV" by itself.

## Cause

1. macOS 15 decides the monitor is a TV, probably from its EDID (TV-style flags such as underscan and audio). This happens over HDMI and USB-C alike.
2. With **"When connected to TV" = Ask What to Show** (`TVConnectPolicy` 0), macOS connects the TV as a separate output and Control Center puts a blank "shield" window on it while it waits to ask what to show. The question never appears (Control Center logs `waitingForCapabilities` and stops there).
3. macOS saves that state in its display layouts, with the display marked `IndependentOutput`, in `~/Library/Preferences/ByHost/com.apple.windowserver.displays.*.plist` and `/Library/Preferences/com.apple.windowserver.displays.plist`. It reapplies the saved layout on every connect and restart, before the TV setting is checked.

## Fix

```
./fix-tv-display.sh            # check only, changes nothing
./fix-tv-display.sh --apply    # back up, fix (asks for your admin password once)
# then restart the Mac with the monitor plugged in
```

`--apply` backs up both settings files to `~/Desktop/display-settings-backup-<time>/`, then:

- sets "When connected to TV" to **Use as Extended Display** (`TVConnectPolicy` 4);
- removes every saved layout with a display marked `IndependentOutput` from both files. Other displays caught in the same state lose their saved arrangement and are set up fresh next time they connect.

Restart right after, and don't plug in or unplug any display first, because macOS rewrites these files when displays change. To undo, run `./fix-tv-display.sh --restore <backup folder>` and restart.

It uses only tools that ship with macOS (`defaults`, `plutil`, `log`), so nothing needs installing.

## Check the cable first

None of this helps if the cable can't carry video. Many USB-C cables, including most charging cables, carry only power and USB 2.0 data. Use a Thunderbolt 3/4/5, USB4, or USB-C 10Gbps cable rated for video, plugged into the monitor's full-featured USB-C port. On a Mac you can see whether video negotiated in the USB-C port's `TransportsActive` value in `ioreg -l`, which should include `DisplayPort` and not just `CC`.

## Limits

- Tested only on macOS 15.7.3. The value 4 for "Use as Extended Display" was taken from that version, so check `--check` output on other versions before applying.
- `FIX_TV_DISPLAY_SANDBOX=<dir>` runs against copies (`user.plist` and `system.plist` in that folder) instead of the live settings. That's how the script was tested.
