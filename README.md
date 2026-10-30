# monitor-input

Switch a monitor's input source (DisplayPort / HDMI 1 / HDMI 2) from a tray icon or a global hotkey, on Windows and macOS.

## How it works

Monitors accept commands over **DDC/CI**, an I2C channel inside the DP/HDMI cable (address `0x37`).
Input selection is the VESA MCCS VCP code **`0x60` (Input Source)**.
ASUS DisplayWidget does exactly the same thing: `DisplayWidget.exe` calls `SetVCPFeature` from `dxva2.dll`,
and the input values in its UI (`ui/html/main.html`) are the standard MCCS ones:

| Input         | VCP 0x60 value |
|---------------|----------------|
| DisplayPort   | `0x0F` (15)    |
| DisplayPort 2 | `0x10` (16)    |
| HDMI 1        | `0x11` (17)    |
| HDMI 2        | `0x12` (18)    |
| USB-C         | `0x13` (19)    |

Run `monitor-input list` to see which values your monitor advertises.

Wire format of a write: `51 84 03 60 00 <value> <checksum>`, checksum = XOR of all bytes and `0x6E`.

## Windows

```
windows\build.cmd
```

Builds with the C# compiler that ships with Windows (.NET Framework 4.x), nothing to install. Produces:

* `monitor-input.exe` - CLI: `list`, `get`, `set hdmi1`, `set dp,hdmi1` (cycles between the listed inputs)
* `monitor-input-tray.exe` - tray app:
  * left click on the icon opens a small window with a button per supported input
  * global hotkeys from `monitor-input.ini` (created next to the exe on first run):
    ```
    monitor = auto
    Ctrl+Alt+1 = dp
    Ctrl+Alt+2 = hdmi1
    Ctrl+Alt+3 = hdmi2
    ```
  * right click menu: Start with Windows, Edit hotkeys, Reload hotkeys, Exit

## macOS (Apple Silicon)

```
cd mac && ./build.sh             # needs Xcode Command Line Tools
./monitor-input list
./monitor-input hdmi1
./install-autostart.sh           # menu bar agent with hotkeys, starts at login
```

Hotkeys live in `~/.config/monitor-input.conf` (default `ctrl+opt+1/2/3`).
They are registered with Carbon `RegisterEventHotKey`, so no Accessibility permission is needed.

Apple Silicon has no public DDC API, so this uses the private `IOAVServiceWriteI2C`
(same approach as MonitorControl, BetterDisplay and m1ddc).

## Limitations

* Most monitors only accept DDC/CI from the **active** input, so the computer currently on screen
  is the one that switches away: Windows -> `Ctrl+Alt+2` -> Mac, Mac -> `Ctrl+Opt+1` -> Windows.
* DDC/CI must be enabled in the monitor OSD (ASUS: System Setup -> DDC/CI).
* Mac: the built-in HDMI port of the M1 Mac mini and some M1/M2 models does not pass DDC; use USB-C/Thunderbolt to DP/HDMI.
* Intel Macs are not supported (different API, IOFramebuffer); use `ddcctl` there.
