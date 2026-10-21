# mpv Radio Tray

A lightweight tray/menu-bar internet radio player for Linux and macOS.

The two implementations share a purpose and a station-list format, with native
interfaces and different playback backends. The historical project name remains
`mpv-radio-tray`: **Linux uses mpv; macOS uses AVFoundation and does not require mpv.**

| Feature | Linux | macOS |
| --- | --- | --- |
| UI | GTK tray | Native AppKit menu bar |
| Main language | Python | Swift |
| Playback backend | External mpv process | AVFoundation / AVPlayer |
| mpv required | Yes | No |
| Recovery | mpv IPC/watchdog | AVFoundation observations/watchdog |
| Bluetooth/output routing | BlueZ + PulseAudio, or PipeWire through `pipewire-pulse` | CoreAudio output discovery + AVPlayer routing; pairing managed by macOS |
| Remembered output | Requested Bluetooth address or local/default choice saved; current sink resolved before playback | Physical output UID/name persisted; missing selected output suspends playback |
| AirPlay | No dedicated AirPlay integration | Native Apple picker attached to the radio AVPlayer; discovery/receiver limitations apply |
| Station file | `~/.config/mpv-radio-tray/stations.txt` | `~/Library/Application Support/MPV Radio Tray/stations.txt` |
| App format | Python tray script + `.desktop` launcher | Locally built `.app` bundle |
| Startup | Starts stopped | Starts stopped; menu bar only, no Dock icon |

## Stations

Both platforms use plain-text station files with one entry per line:

```text
# Station name|stream URL
Galaxy 92.92|https://netradio.live24.gr/galaxy9292
RED FM 96.3|https://stream.radiojar.com/redfm963
```

The format is `Station name|https://stream-url`. Blank lines and lines beginning
with `#` are ignored; order is preserved. Use direct HTTP/HTTPS audio streams.
For RadioJar, keep the clean station URL instead of a redirected token URL.

Edit the platform-specific file shown in the table. Linux reads it when building
the tray menu; relaunch to ensure an edited list is loaded. macOS provides
**Edit Stations…** and **Reload Stations**. Its first launch copies the Linux
station file if present, otherwise bundled defaults, without overwriting an
existing macOS file or changing Linux configuration.

The parsers share the format, with different validation: Linux skips lines
without a separator; macOS requires a name and an HTTP/HTTPS URL with a host.
An invalid macOS edit shows a line-number error and retains the previous valid
menu. Reloading does not change a stream already playing; reselect it to use an
edited URL. A valid URL does not guarantee that the stream is playable.

## Linux

### Dependencies

On Debian/Ubuntu-based systems:

```sh
sudo apt install mpv python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 bluez pulseaudio-utils
```

Use the distribution's Python 3 and GTK bindings. `bluetoothctl` comes from BlueZ;
`pactl` comes from the PulseAudio utilities. PipeWire systems need the
`pipewire-pulse` compatibility service and an mpv build with PulseAudio support.
The app supports PulseAudio and PipeWire Bluetooth sink naming; older `pactl`
versions without JSON use a fixed-locale text fallback. It does not use a native
PipeWire control interface.

### Install locally

From a checkout of this repository, quit the running radio before replacing its
script. These commands preserve an existing station file:

```sh
mkdir -p "$HOME/.local/bin" "$HOME/.config/mpv-radio-tray"
install -m 755 mpv-radio-tray "$HOME/.local/bin/mpv-radio-tray"
if [ ! -e "$HOME/.config/mpv-radio-tray/stations.txt" ]; then
    install -m 644 stations.txt "$HOME/.config/mpv-radio-tray/stations.txt"
fi
"$HOME/.local/bin/mpv-radio-tray"
```

Alternatively run `./mpv-radio-tray` directly from the checkout for testing. This
uses your normal stations/config; there is no separate test-config environment
variable. Keep only one copy running. The Linux app starts stopped and offers
station selection, **Output**, **Stop** and **Quit**.

### Optional XFCE/application launcher

Create a launcher with the installed script's absolute path:

```sh
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/mpv-radio-tray.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=mpv Radio Tray
Comment=Small radio tray player using mpv
Exec="$HOME/.local/bin/mpv-radio-tray"
Icon=multimedia-player
Terminal=false
Categories=Audio;Player;
StartupNotify=false
EOF
chmod 644 "$HOME/.local/share/applications/mpv-radio-tray.desktop"
```

This can be used from XFCE's application menu or panel launcher. The repository
also includes a PATH-based [desktop entry](mpv-radio-tray.desktop); using it
requires `~/.local/bin` in the desktop session's `PATH`.

### Output and remembered Bluetooth routing

**Output** offers **System default**, **Computer** (a non-Bluetooth sink), and
devices listed by `bluetoothctl devices`. Pair/trust the speaker normally first;
the app does not pair devices or change Bluetooth profiles.

The requested output is saved in `~/.config/mpv-radio-tray/output.json`. The menu
dot represents that preference; a separate status line reports whether it is
preparing, routed or unavailable. On the first run after upgrading from a version
without persistence, select the speaker once to establish the saved preference.

For every station start, station switch, output selection and watchdog restart:

1. Check the remembered Bluetooth address and request connection if needed.
2. Wait for its current audio sink, even if the speaker was already connected.
3. Resolve the current sink name/index instead of trusting a previous session's ID.
4. Start mpv explicitly on `pulse/<sink>`, muted; verify that mpv's own stream uses
   that sink before unmuting and reporting **Bluetooth audio routed**.

Bluetooth connection, device enumeration and sink discovery run in background
workers. Stop, Quit, station changes and output changes invalidate stale work.
The connection command has a 12-second timeout, sink discovery another 12 seconds,
and muted stream verification 20 seconds, plus bounded probes/cleanup.

If the speaker or route cannot be verified, playback stays stopped, the preference
remains selected, and the status offers a retry. There is **no intentional fallback
to laptop speakers** for an explicit Bluetooth choice. Click the station again,
reselect the output, or choose another output to retry. Slow streams, missing
tools or an unusable audio profile can also produce this unavailable state.

Only this app's mpv process is routed; the system default and other applications'
streams are not changed. The watchdog stops playback if its Bluetooth route is
lost. An audio server can independently move an already-playing stream before
that periodic check, so brief audio elsewhere after disconnection remains
possible. Startup verification is not a system-wide routing lock.

Linux has no dedicated AirPlay discovery, picker or receiver support in this app.

### Recovery and shutdown

mpv uses a 16 MiB forward cache, 1 MiB back cache and 10-second readahead preference
without changing the user's global mpv configuration. A five-second background
IPC watchdog detects process exit, stream end, missing IPC, continuous buffering
for 25 seconds, or playback that progressed and then stalled for 30 seconds.
Startup grace and a 30-second restart cooldown prevent premature/rapid retries.
Every Bluetooth restart repeats connection and current-sink resolution.

**Stop** cancels playback/preparation. **Quit**, logout signals and normal GTK
shutdown terminate/reap the mpv process group. A Linux parent-death signal also
terminates the owned playback process if the tray process dies unexpectedly.

## macOS

### Build and install locally

Requires **macOS 13+** and Apple Command Line Tools with **Swift 5.9+**. Install
the tools with `xcode-select --install` if needed. There are no third-party package
or Homebrew mpv requirements.

From the repository root:

```sh
./macos/scripts/build-app.sh
open "macos/dist/MPV Radio Tray.app"
```

The build targets the current Mac's architecture, treats Swift warnings as errors,
and packages the app icon, adaptive monochrome menu-bar icon and default stations.
It uses **ad hoc signing for local use**, without Developer ID signing or
notarization. No notarized binary or Mac App Store package is provided; deployment
target compatibility does not establish testing on every macOS release or Mac.

To install, quit every running copy. For an upgrade, move the previous application
bundle out of Applications first so obsolete resources are not carried forward;
station configuration lives outside the bundle and should be retained. Then:

```sh
ditto "macos/dist/MPV Radio Tray.app" "/Applications/MPV Radio Tray.app"
codesign --verify --deep --strict "/Applications/MPV Radio Tray.app"
open "/Applications/MPV Radio Tray.app"
```

The native AppKit app starts stopped on every launch, including login startup,
with no Dock icon. It owns one persistent AVPlayer; station switches replace its
item. **Stop** clears the station, while media Pause retains it and releases the
live connection. **Resume** reconnects at the live edge. Quit releases media,
observers, timers and media-command handlers.

### Outputs and AirPlay

**Output** selects **System Default** or usable exposed CoreAudio outputs such as
built-in, USB, Bluetooth, display and aggregate devices. Selection sets the radio
player's output UID; it does not set the global system output. Pair Bluetooth
through macOS. Input-only, unavailable, UID-less, duplicate, virtual software and
AirPlay-transport entries are excluded from this direct output list.

The requested physical output UID/name persist across application launches,
station changes, recovery and sleep/wake. If it disappears, radio suspends until
it returns or another output is chosen. Pause, Stop and sleep prevent unwanted
resumption. **Refresh Outputs** refreshes the exposed CoreAudio inventory.

**AirPlay…** is enabled while radio plays. It opens a compact native popover;
click the Apple route-picker button inside to choose a receiver. AVRoutePickerView
uses the same AVPlayer as radio. Opening Apple's receiver list selects **System
Default** for the radio so a fixed physical UID cannot pin it elsewhere; this
preference persists even if selection is cancelled. Opening only the host popover
does not change Output. The host closes after the receiver list dismisses.

AVRouteDetector supplies a **routes available** hint, not a receiver list or proof
of activation. AirPlay receivers are managed by Apple's picker and macOS rather
than saved as direct CoreAudio output preferences. Refresh Outputs does not
discover AirPlay receivers or repair system-level discovery.

Playback through the native picker to one receiver, with Music staying closed,
was manually confirmed on the development Mac after Now Playing/media-command
integration. Radio also followed a system-selected receiver and returned to
speakers in earlier testing with Output = System Default; that separate path
was not rechecked after media-command registration. Discovery has varied during
testing, including receivers disappearing from macOS's own list. Other receivers,
macOS versions and continuity across reconnects still need manual validation.
There is no custom receiver browser or mpv fallback.

### Recovery, streams and logs

AVFoundation item/player observations and a five-second watchdog handle failures,
stream end, 30 seconds of continuous waiting or stalled progress, a 12-second
startup grace, and a 30-second retry cooldown. Pause and Stop suppress recovery.
Sleep releases the item; wake reconnects a selected station unless paused/stopped
or its requested output is unavailable. The 10-second forward-buffer setting is
a preference, not a fixed memory cap.

Direct HTTP/HTTPS streams are supported subject to AVFoundation's codec/container
and server-response support; HLS is not required. Media-only ATS permission allows
configured HTTP radio, which is unencrypted; prefer HTTPS where available.
**Show Logs** opens `~/Library/Logs/MPV Radio Tray/`, with rotating playback,
output and lifecycle diagnostics. See the [macOS guide](macos/README.md) for details.

## Architecture

```text
Linux: GTK → Python → mpv → PulseAudio / PipeWire (pipewire-pulse)
                           └─ Bluetooth devices connected through BlueZ

macOS: AppKit → Swift → AVFoundation / AVPlayer
                       ├─ CoreAudio output discovery and UID routing
                       └─ Apple's native AirPlay picker
```

mpv provides Linux streaming and per-process routing through its IPC/audio-device
interface. AVFoundation provides macOS media controls, lifecycle and native routing
APIs. Identical playback backends are not a design requirement: reliable native
behavior takes priority. Neither implementation changes the global output as part
of its direct per-player output selection.

## Building / Testing

Run Linux's headless regression tests and syntax checks from the repository root:

```sh
python3 -m unittest discover -s tests -v
python3 -m py_compile mpv-radio-tray
```

The tests simulate GTK, Bluetooth, audio-server responses and mpv. Linux-only
parent-death tests run on Linux and are skipped on macOS. The remembered-Bluetooth
acceptance test has also passed on the user's real Linux laptop; automated tests
do not replace checks on other speakers/audio-server configurations.

For macOS, use the maintained scripts with Swift warnings treated as errors:

```sh
./macos/scripts/build-app.sh
./macos/scripts/check.sh
./macos/scripts/check.sh --outputs
./macos/scripts/check.sh --popover
./macos/scripts/check.sh --stream https://netradio.live24.gr/galaxy9292
./macos/scripts/check.sh --stream https://stream.radiojar.com/redfm963
python3 macos/scripts/test-app-startup.py "macos/dist/MPV Radio Tray.app"
```

The core checks cover stations, playback intent/recovery and output models.
Native checks require a logged-in graphical macOS session; they test output
inventory, preferences, device changes, shared-player popover lifecycle, muted
stream playback, media controls and clean shutdown. No receiver is selected
automatically. Real sound, system media-command delivery and AirPlay routing
require [manual acceptance](macos/README.md#manual-acceptance).

On Linux, verify these after changing audio/routing code:

1. Select a paired speaker once, play, Quit, relaunch, and start a station without
   touching Output. Confirm speaker audio and **Bluetooth audio routed**.
2. Repeat initially disconnected, then powered off. Check reconnection, bounded
   failure, silence while waiting, the retained preference and a responsive tray.
3. Power it on and retry; check station switching, manual re-selection and
   watchdog restart retain routing. Stop/Quit must cancel pending work.
4. Test Computer/System default and confirm other applications remain unchanged.

Generated bundles, compiler caches and Python bytecode are ignored; tests/builds
write temporary or ignored output. No third-party packages are downloaded by the
macOS build scripts.

## License

This repository is licensed under the [MIT License](LICENSE). Station names,
broadcasts and stream URLs belong to their respective providers; this project
does not claim ownership of third-party radio content or guarantee availability.
