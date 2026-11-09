# lofree-light

Sets a Lofree keyboard's backlight brightness from a time-of-day schedule on macOS.
Tested with the Flow Lite84 (`Air84@Lofree`, USB ID `05ac:024f`, firmware v1.64) over USB.

## Install

```sh
./install.sh      # builds, installs ~/.local/bin/lofree-light, loads a launchd agent
./uninstall.sh
```

The agent runs `lofree-light auto` every 60 seconds. It only talks to the keyboard when a new
schedule slot starts, so brightness changes you make with the Fn keys hold until the next slot.
If the keyboard is unplugged, the slot gets applied the next time it is plugged in.

No macOS permissions are needed (see [Transport](#transport)).

## Schedule

`~/.config/lofree-light/schedule.json`. Levels are `"off"` or `0`–`4`. Times are 24-hour local time.
Each entry holds until the next one, wrapping around midnight.

```json
{
  "schedule": [
    { "time": "07:00", "level": "off" },
    { "time": "17:00", "level": 4 }
  ]
}
```

Edits take effect within a minute. No reload is needed.

## Commands

```sh
lofree-light set 3            # or: set off
lofree-light auto --dry-run   # which slot is in effect, and when it was last applied
lofree-light auto --force     # re-apply the current slot now
```

Log: `~/Library/Logs/lofree-light.log`. It only records changes and errors.

## Protocol

Taken from Lofree's web configurator (https://www.lofree.tech/keyboard/). The keyboard has a
vendor HID collection on usage page `0xFF02`, which uses 16-byte reports with report ID 8.
Requests have the form `[cmd, 0, addrHi, addrLo, len|0x80, data…, checksum]`.
Command 8 reads the keyboard's settings memory and command 7 writes it. The backlight
on/off flag is at `0x2132` and the current effect mode is at `0x2130`. Each mode has its own
brightness, at `0x2160 + mode*32 + 2`. See the header of `Sources/main.swift` for details.

## Transport

Commands go out as plain USB HID `SET_REPORT` control transfers to the keyboard's vendor
interface. They don't go through macOS's HID system. That interface also carries keystrokes,
so opening it through the HID system would need Input Monitoring permission. A control
transfer doesn't.

The catch is that this channel is write-only. The keyboard's replies go to the HID driver,
and the firmware returns zeros for `GET_REPORT`. So the tool can't read the current settings.
Because brightness is stored per light mode and the active mode can't be read, every
brightness change also sets the keyboard to mode 0, with color index 0 and speed 2 (the values
this keyboard came with). If you pick a different lighting effect with the Fn keys, the next
schedule slot switches it back.

Over Bluetooth or the 2.4 GHz dongle the tool does nothing. Only a USB connection is supported.
