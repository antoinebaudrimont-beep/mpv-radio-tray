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

Use the tray menu's `Output` submenu to choose **System default**, **Computer**
(a non-Bluetooth sink), or a Bluetooth device known to `bluetoothctl`.
The dot represents the **requested preference**, not proof of a live connection.
The status line separately reports preparation, routing, or an unavailable output.

The preference is saved in `~/.config/mpv-radio-tray/output.json`. Only the
Bluetooth address or local/default choice is saved; sink names and numeric IDs
are resolved afresh. Earlier versions did not persist an output preference and
could infer the dot from the system default. Select your speaker once after
upgrading to establish the saved preference.

Bluetooth devices must already be paired or otherwise listed by:

```bash
bluetoothctl devices
```

On station start, station switch, manual output selection, and watchdog restart,
the app checks the requested Bluetooth device, connects if necessary, and waits
for its current sink. An already-connected device is still resolved again.
Bluetooth connection, enumeration, and sink discovery run outside the GTK loop.
The device must already be paired, and some desktops may require it to be trusted.

mpv starts with the explicit `pulse/<sink>` device and initially muted. The app
checks that mpv's own PulseAudio sink-input is on the resolved sink before
unmuting and reporting **Bluetooth audio routed**. Connection/sink/startup
failure leaves playback stopped, retains the requested preference, and shows a
retry message. There is no intentional fallback to laptop speakers. Click the
station again (even if checked), reselect the output, or choose another output
to retry. Stop and Quit cancel pending work. Changing output restarts the current
station through the same preparation path.

A connection command is limited to 12 seconds, sink discovery to another
12 seconds, and muted mpv route verification to 20 seconds; individual probes
and shutdown also have bounded timeouts. There is no endless automatic retry
loop for an unavailable output. Missing tools, an unusable audio profile, an
unverifiable stream, or a slow/failing radio stream can produce an unavailable
message. The app does not pair devices or change Bluetooth profiles.

Routing uses `pactl` and mpv's PulseAudio output on both PulseAudio and PipeWire
with `pipewire-pulse`. Sink matching supports `bluez_sink` and `bluez_output`
names plus Bluetooth address properties, and prefers an available A2DP sink.
Older `pactl` versions without JSON use text output with a fixed locale. Native
PipeWire-only installations need the PulseAudio compatibility service and an mpv
build with PulseAudio support.

The tray app routes only `mpv`; it does not change the system-wide default or
other applications' audio. During playback the watchdog checks the actual route
and stops if it is lost. This is periodic detection: an audio server that moves
an already-playing stream after disconnection could briefly send sound elsewhere
before the check runs. Startup verification is not a system-wide routing lock.

### Recovery behavior

The app gives its audio-only mpv process a 16 MiB forward cache and a 1 MiB
back cache, without changing the user's global mpv configuration.

It checks mpv's private IPC socket every five seconds without blocking the tray
UI. If mpv reports `paused-for-cache` continuously for 25 seconds, exits,
reaches EOF, stops responding through IPC, or reports playback time that moved
and then stalled for 30 seconds, the tray app restarts the same station. A
30-second restart cooldown prevents rapid restart loops.

The tray process is not restarted, so the selected station is preserved.

### Linux validation

Run the headless regression suite from the repository root:

```sh
python3 -m unittest discover -s tests -v
```

The tests simulate GTK dispatch, Bluetooth, PulseAudio/PipeWire responses and
mpv; Linux parent-death tests run only on Linux. They do not prove hardware audio.
On the Linux laptop, quit the installed app and run this branch directly from a
separate checkout (`./mpv-radio-tray`) before replacing the installed executable.
It uses your normal stations/config and writes the new `output.json` preference.
Select the speaker once on the first run to establish that preference, then:

1. Pair/trust the speaker normally, select it in Output, start a station, and
   confirm sound on the speaker and **Bluetooth audio routed** in Output.
2. Quit and relaunch with the speaker connected. Do not touch Output. Start a
   station; confirm it plays on the remembered speaker without laptop audio.
3. Repeat with the paired speaker initially disconnected but powered on. Confirm
   reconnection and silence while preparing/verifying, followed by speaker audio.
4. Repeat with the speaker powered off. Confirm a bounded unavailable message,
   the requested checkmark remains, and Output/Stop/Quit remain usable.
5. Power it back on and click the checked station to retry. Also test manual
   re-selection, station switching, Computer/System default, and quitting during
   connection. Confirm no late worker starts playback after Stop or Quit.
6. Interrupt the stream or terminate the owned mpv process during playback;
   confirm watchdog restart uses the speaker again. Power off a playing speaker
   separately to check route-loss handling and any server-driven fallback delay.

Check that other applications and the system default remain unchanged throughout.

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
