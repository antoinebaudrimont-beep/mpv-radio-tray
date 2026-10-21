# MPV Radio Tray

A lightweight tray/menu-bar internet radio player for Linux and macOS.

## Platforms

| Feature | Linux | macOS |
| --- | --- | --- |
| UI | GTK tray | Native AppKit menu bar |
| Language | Python | Swift |
| Playback | External mpv process | AVFoundation / AVPlayer |
| mpv dependency | Yes | No |
| Radio recovery | mpv IPC watchdog | AVFoundation observations and watchdog |
| Bluetooth | BlueZ and the Linux audio stack | macOS system audio and pairing |
| AirPlay | No dedicated integration | Native Apple route picker; receiver support varies |
| Station config | `~/.config/mpv-radio-tray/stations.txt` | `~/Library/Application Support/MPV Radio Tray/stations.txt` |
| Packaging | Script and `.desktop` launcher | Locally built `.app` bundle |
| Startup | Tray application, no automatic playback | Menu-bar-only application, starts stopped |

Linux uses mpv because it is a lightweight streaming backend that integrates
well with Linux audio systems. macOS uses AVFoundation for native audio routing,
lifecycle, sleep/wake and AirPlay APIs. The project shares behavior and the
`Station name|stream URL` format while keeping each implementation appropriate
to its platform.

## Linux

### Install dependencies

```bash
sudo apt install mpv python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 bluez pulseaudio-utils
```

### Install locally

```bash
mkdir -p ~/.local/bin ~/.config/mpv-radio-tray ~/.local/share/applications
cp mpv-radio-tray ~/.local/bin/mpv-radio-tray
cp stations.txt ~/.config/mpv-radio-tray/stations.txt
cp mpv-radio-tray.desktop ~/.local/share/applications/mpv-radio-tray.desktop
chmod +x ~/.local/bin/mpv-radio-tray
```
#### Create an XFCE launcher

On XFCE, you can create the application launcher file manually with:

```bash
mkdir -p ~/.local/share/applications

cat > ~/.local/share/applications/mpv-radio-tray.desktop <<EOF
[Desktop Entry]
Type=Application
Name=mpv Radio Tray
Comment=Small radio tray player using mpv
Exec=$HOME/.local/bin/mpv-radio-tray
Icon=multimedia-player
Terminal=false
Categories=Audio;Player;
StartupNotify=false
EOF
chmod 644 ~/.local/share/applications/mpv-radio-tray.desktop
xfce4-panel -r
```

Make sure `~/.local/bin` is in your `PATH`, then start:

```bash
mpv-radio-tray
```

### Stations

Edit:

```text
~/.config/mpv-radio-tray/stations.txt
```

Use one station per line:

```text
Station name|https://example.com/stream
```

For RadioJar streams, keep the clean URL rather than redirected token URLs.

### Output

Use the tray menu's `Output` submenu to switch between the computer's normal
audio sink and Bluetooth devices known to `bluetoothctl`.
The selected output is marked with a dot drawn in the current GTK theme color.

Bluetooth devices must already be paired or otherwise listed by:

```bash
bluetoothctl devices
```

When you choose a Bluetooth device, the app asks `bluetoothctl` to connect to
it, waits for the matching audio sink, then tells `mpv` to use that sink. The
device must already be paired, and some desktops may require it to be trusted.
The tray app routes only `mpv`; it does not change the system-wide default
output or the audio used by other applications. The selected output is reused
when the current station is restarted.

### Recovery behavior

The app gives its audio-only mpv process a 16 MiB forward cache and a 1 MiB
back cache, without changing the user's global mpv configuration.

It checks mpv's private IPC socket every five seconds without blocking the tray
UI. If mpv reports `paused-for-cache` continuously for 25 seconds, exits,
reaches EOF, stops responding through IPC, or reports playback time that moved
and then stalled for 30 seconds, the tray app restarts the same station. A
30-second restart cooldown prevents rapid restart loops.

The tray process is not restarted, so the selected station is preserved.

## macOS

Requires **macOS 13+** and Apple Command Line Tools with **Swift 5.9+**. Install
the tools with `xcode-select --install` if needed. No Homebrew mpv or third-party
packages are required.

From the repository root:

```sh
./macos/scripts/build-app.sh
open "macos/dist/MPV Radio Tray.app"
```

To install locally, quit every running copy first, then copy the bundle:

```sh
ditto "macos/dist/MPV Radio Tray.app" "/Applications/MPV Radio Tray.app"
codesign --verify --deep --strict "/Applications/MPV Radio Tray.app"
open "/Applications/MPV Radio Tray.app"
```

For an upgrade, remove the previous application bundle before copying so old
resources are not carried forward. Keep the station configuration in place.
The build is **ad hoc signed for local use**, not notarized or App Store approved.
This repository publishes source; it does not provide a notarized binary or a
Mac App Store package. The build targets the current Mac's architecture.

The app starts stopped and displays a radio icon in the menu bar, with no Dock
icon. Choose a station to play, switch stations from the menu, and use **Stop**
to clear playback. Recovery handles stream failures, prolonged buffering and
stalled playback; sleep/wake reconnects a selected station, and Quit releases
playback and recovery.

Stations live in `~/Library/Application Support/MPV Radio Tray/stations.txt`.
Use **Edit Stations…** and **Reload Stations**. The first launch copies an
existing Linux-format configuration if present; existing files are preserved.

**Output** selects System Default or usable exposed CoreAudio devices, including
physical Bluetooth/USB/display audio. A missing selected device suspends radio
until it returns or another output is chosen. The app does not change the global
system output. Pair Bluetooth devices through macOS.

**AirPlay…** is separate from Output and is enabled while radio plays. It hosts
Apple's native route picker attached to the same AVPlayer. Receiver names come
from Apple's picker, not CoreAudio enumeration. Opening the receiver list selects
System Default for the radio; this preference persists if the picker is cancelled.
Now Playing/media-command registration handles AirPlay Play commands in the radio
app. Playback to one receiver without launching Music has been manually verified
on the development Mac; other receivers and macOS versions remain unverified.
System Default also followed externally selected AirPlay to a receiver and back
to speakers in earlier testing. AirPlay availability and activation depend on
macOS and the receiver, and output/availability indicators do not prove audible
routing. Codec/container support follows AVFoundation; there is no mpv fallback.

Build, installation, output behavior, logs and the maintained automated/manual
checks are documented in [the macOS guide](macos/README.md).
