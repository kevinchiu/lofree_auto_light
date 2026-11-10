# lofree-light

Switches a Lofree keyboard's backlight on and off with the MacBook's built-in keyboard backlight
while the lid is open. When the lid is closed, it uses a time-of-day schedule instead. Brightness
and lighting effect are yours to set with the keyboard's Fn keys; the tool never changes them.
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
whether you set it yourself or auto-brightness did. While the MacBook's backlight is on, the Lofree's
is on; when the slider is at 0, or auto-brightness has turned it off, the Lofree's is off.

- **Near zero:** after switching off, the Lofree comes back on only once the slider is above 2%, so
  auto-brightness hovering just above zero doesn't flip it back and forth.
- **Slider drags:** a change is written only after it has held for 10 seconds, so dragging the
  slider through zero costs nothing.
- **Idle dimming is ignored:** macOS switches the built-in light off a few seconds after the last
  input from any keyboard or mouse. Mirroring that would blink the Lofree off at every pause, so
  the Lofree stays as it was. It has its own idle timeout.

## Lid closed: schedule

`~/.config/lofree-light/schedule.json`. Each `level` is `"on"` or `"off"` (numbers 0–4 from older
schedules count as `"on"`). Times are 24-hour local time.
Each entry holds until the next one, wrapping around midnight. Edits are picked up within a second.

```json
{
  "schedule": [
    { "time": "07:00", "level": "off" },
    { "time": "17:00", "level": "on" }
  ]
}
```

## Saving writes

Switching the light on or off is one write to the keyboard's settings memory, which is flash memory
and wears out after a limited number of writes. Lofree doesn't publish how many writes its chip is
rated for, so the tool writes as little as it can:

- **Only when the state should change.** A write happens when the tool wants the light the other
  way from how it last set it. Restarting, replugging the keyboard, or opening or closing the lid
  when the MacBook and the schedule agree costs nothing. With the default schedule, that's 2
  writes a day.
- **A daily limit of 10 writes.** Once it's used up, the tool leaves the light as it is until
  midnight and says so in the log. `lofree-light set` isn't held to the limit, but its writes count
  toward it.

If you switch the light with the Fn keys, it stays that way until the tool next wants to switch it.

The write count is kept in `~/.local/state/lofree-light/writes.json`, along with what the tool last
wrote. `lofree-light status` shows it.

## Commands

```sh
lofree-light status   # lid state, MacBook backlight, what `run` wants, and writes used
lofree-light set on   # switch the Lofree's light once (or: set off)
lofree-light run      # the loop launchd runs
```

Log: `~/Library/Logs/lofree-light.log`. It records each switch on or off, connects, disconnects,
the daily limit being reached, and errors.

## Protocol

Taken from Lofree's web configurator (https://www.lofree.tech/keyboard/). The keyboard has a
vendor HID collection on usage page `0xFF02`, which uses 16-byte reports with report ID 8.
Requests have the form `[cmd, 0, addrHi, addrLo, len|0x80, data…, checksum]`.
Command 8 reads the keyboard's settings memory and command 7 writes it. The backlight
on/off flag is at `0x2132`, and it's the only thing this tool writes. See the header of
`Sources/main.swift` for the other fields.

The MacBook's backlight is read through `KeyboardBrightnessClient`, from the private CoreBrightness
framework. If a macOS update removes or changes it, `run` falls back to the schedule full time.

## Transport

Commands go out as plain USB HID `SET_REPORT` control transfers to the keyboard's vendor
interface. They don't go through macOS's HID system. That interface also carries keystrokes,
so opening it through the HID system would need Input Monitoring permission. A control
transfer doesn't.

The catch is that this channel is write-only. The keyboard's replies go to the HID driver,
and the firmware returns zeros for `GET_REPORT`. So the tool can't read the current settings,
including whether you've switched the light with the Fn keys.

Over Bluetooth or the 2.4 GHz dongle the tool does nothing. Only a USB connection is supported.

## License

MIT. See [LICENSE](LICENSE).
