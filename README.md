# lofree-light

Makes a Lofree keyboard's backlight follow the MacBook's built-in keyboard backlight while the lid
is open. When the lid is closed, it uses a time-of-day schedule instead.
Tested with the Flow Lite84 (`Air84@Lofree`, USB ID `05ac:024f`, firmware v1.64) over USB, on a
MacBook Pro (M1 Max).

> **Not affiliated with Lofree.** This is an unofficial tool built from a reading of Lofree's
> public web configurator. It writes to your keyboard's stored settings and can't read them back
> to check. It has only been tested on the keyboard above. Use it at your own risk. Lofree's
> configurator at https://www.lofree.tech/keyboard/ can restore defaults if something goes wrong.
>
> It only writes to USB devices with "Lofree" in their name and with one of the wired-keyboard
> IDs Lofree's configurator lists.

## Install

```sh
./install.sh      # builds, installs ~/.local/bin/lofree-light, keeps `lofree-light run` running via launchd
./uninstall.sh
```

No macOS permissions are needed (see [Transport](#transport)).

## Lid open: follow the MacBook

`run` checks the built-in keyboard backlight once a second. That's the Keyboard Brightness slider,
whether you set it yourself or auto-brightness did. The slider maps onto the Lofree in five equal bands:

| MacBook slider | Lofree |
|---|---|
| 0% | off |
| 1–19% | 0 |
| 20–39% | 1 |
| 40–59% | 2 |
| 60–79% | 3 |
| 80–100% | 4 |

- **Bouncing at band edges:** a small margin keeps auto-brightness from flipping the Lofree back
  and forth when the slider sits near a band edge.
- **Slider drags:** a new level is written only after it has held for two checks, so dragging the
  slider produces one write.
- **Idle dimming is ignored:** macOS switches the built-in light off a few seconds after the last
  input from any keyboard or mouse. Mirroring that would blink the Lofree off at every pause, so
  the Lofree keeps its last level instead. It has its own idle timeout.

## Lid closed: schedule

`~/.config/lofree-light/schedule.json`. Levels are `"off"` or `0`–`4`. Times are 24-hour local time.
Each entry holds until the next one, wrapping around midnight. Edits are picked up within a second.

```json
{
  "schedule": [
    { "time": "07:00", "level": "off" },
    { "time": "17:00", "level": 4 }
  ]
}
```

A level is written when the lid closes and when a new slot starts.

Brightness changes you make with the Fn keys are left alone until the next change of source: a new
level from the MacBook, the lid opening or closing, or a new schedule slot. Unplugging and
replugging the keyboard re-applies the current level.

## Commands

```sh
lofree-light status   # lid state, MacBook backlight, and the level `run` would set
lofree-light set 3    # set the Lofree once (or: set off)
lofree-light run      # the loop launchd runs
```

Log: `~/Library/Logs/lofree-light.log`. It records level changes, connects, disconnects and errors.

## Protocol

Taken from Lofree's web configurator (https://www.lofree.tech/keyboard/). The keyboard has a
vendor HID collection on usage page `0xFF02`, which uses 16-byte reports with report ID 8.
Requests have the form `[cmd, 0, addrHi, addrLo, len|0x80, data…, checksum]`.
Command 8 reads the keyboard's settings memory and command 7 writes it. The backlight
on/off flag is at `0x2132` and the current effect mode is at `0x2130`. Each mode has its own
brightness, at `0x2160 + mode*32 + 2`. See the header of `Sources/main.swift` for details.

The MacBook's backlight is read through `KeyboardBrightnessClient`, from the private CoreBrightness
framework. If a macOS update removes or changes it, `run` falls back to the schedule full time.

## Transport

Commands go out as plain USB HID `SET_REPORT` control transfers to the keyboard's vendor
interface. They don't go through macOS's HID system. That interface also carries keystrokes,
so opening it through the HID system would need Input Monitoring permission. A control
transfer doesn't.

The catch is that this channel is write-only. The keyboard's replies go to the HID driver,
and the firmware returns zeros for `GET_REPORT`. So the tool can't read the current settings.
Because brightness is stored per light mode and the active mode can't be read, turning the
light on also sets the keyboard to mode 0, with color index 0 and speed 2 (the values
this keyboard came with). If you pick a different lighting effect with the Fn keys, the next
level change switches it back.

Over Bluetooth or the 2.4 GHz dongle the tool does nothing. Only a USB connection is supported.

## License

MIT. See [LICENSE](LICENSE).
