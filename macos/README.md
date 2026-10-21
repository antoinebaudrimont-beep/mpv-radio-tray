# macOS menu-bar radio

A native Swift/AppKit application with one persistent AVPlayer for radio,
CoreAudio selection for exposed audio outputs, and Apple's native AirPlay picker.
It starts stopped, has no Dock icon, and keeps the project name **MPV Radio Tray**.
The macOS implementation has no mpv dependency. See the [root README](../README.md)
for the platform comparison and Linux instructions.

## Build and local installation

- macOS 13 or later.
- Apple Command Line Tools with Swift 5.9 or later (`xcode-select --install`).
- No third-party packages or external playback executable are required.

From the repository root:

```sh
./macos/scripts/build-app.sh
```

The script compiles an optimized build for the current Mac's architecture with
warnings treated as errors. Temporary compiler caches are removed on exit.
The bundle is `macos/dist/MPV Radio Tray.app`.

Quit every running copy before upgrading. Remove the old application bundle
from Applications if present, then copy and verify the new one:

```sh
ditto "macos/dist/MPV Radio Tray.app" "/Applications/MPV Radio Tray.app"
codesign --verify --deep --strict "/Applications/MPV Radio Tray.app"
open "/Applications/MPV Radio Tray.app"
```

This build uses **ad hoc signing for local use**. It is not notarized, Developer
ID signed, or App Store approved. Source publication does not imply a notarized
binary distribution. No Mac App Store package is provided.

The app appears only in the menu bar and starts stopped on every launch,
including login startup. Optionally add the installed app in System Settings →
General → Login Items.

## Icons

The orange retro-radio application icon and monochrome menu-bar glyph are adapted
from the project owner's supplied artwork. Their transparent PNG masters live in
`Resources/AppIcon.png` and `Resources/MenuBarIconTemplate.png`.
The build script uses macOS `sips`, `iconutil`, and `tiffutil` to package all standard
app-icon sizes and 1×/2× menu-bar images. AppKit tints the menu-bar template for
light, dark, and selected appearances; no separate theme setting is needed.

## Stations and migration

Configuration lives at:

```text
~/Library/Application Support/MPV Radio Tray/stations.txt
```

Existing files are never overwritten. On first launch, the app copies
`~/.config/mpv-radio-tray/stations.txt` if present; otherwise it copies the bundled
macOS defaults. The Linux configuration is only read.

Use **Edit Stations…**, save plain UTF-8 text, then **Reload Stations**:

```text
# Station name|stream URL
Galaxy 92.92|https://netradio.live24.gr/galaxy9292
RED FM 96.3|https://stream.radiojar.com/redfm963
```

Labels, URLs and order are preserved. Comments and blank lines are ignored.
Invalid edits show a line-number error and retain the previous valid menu.
Reload does not interrupt playback; select the station again to apply an edited
URL. Existing configuration, including older URLs, is preserved during upgrade.
The macOS defaults do not change Linux's bundled stations.

## Playback and media controls

Select a station to play. Station changes replace the item on the same AVPlayer.
**Stop** clears the selected station and disables recovery. **Quit** releases
media, observations, timers and media-command handlers.

Public `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` integration publishes
the station as live audio and handles Play, Pause, Stop and Toggle. A Play command
while radio is already playing leaves the stream intact. Pause retains the
station, releases the live connection and prevents watchdog recovery until
**Resume** or a media Play command. Resume reconnects at the live edge. Sleep and
an unavailable output cannot be bypassed by a media Play command. Stop clears
Now Playing metadata, and unsupported seek/skip controls are disabled.

This registration also lets the app handle Play commands sent during AirPlay
activation. Playback through the native picker without launching Music was
manually confirmed on the development Mac with one receiver. The app never
launches, closes or automates Music. Other receivers and macOS versions require
their own checks.

## Outputs

**Output** is the radio's output selector:

- **System Default** sets `AVPlayer.audioOutputDeviceUniqueID` to `nil`.
- An available physical/aggregate output sets that property to its CoreAudio UID.
- **Refresh Outputs** updates the CoreAudio inventory immediately.
- **Sound Settings…** and **Bluetooth Settings…** open macOS output/pairing controls.

The app does not set the global system output. The list includes usable exposed
built-in, USB, Bluetooth, HDMI/DisplayPort and aggregate outputs. Input-only,
unavailable, UID-less, duplicate and declared virtual software devices are
excluded. Filtering uses public transport metadata rather than device names or
UID patterns. Saved preferences for exposed virtual or AirPlay devices reset to
System Default because those transports are not direct Output choices.

The menu refreshes on opening, device/property changes, wake and manual refresh.
CoreAudio listeners cover inventory/default output, name, UID, transport,
output configuration and availability. Routing updates immediately; a root menu
being tracked is rebuilt after it closes.

The requested UID/name persist across application launches, station changes,
recovery, Stop/start and sleep/wake. If a selected physical output disappears,
it becomes **unavailable** and radio suspends. It resumes when that device returns unless
Pause, Stop, sleep or shutdown prevents it. Choose System Default or another
available output to resume on a different destination.

### AirPlay

**AirPlay…** is enabled while radio plays and opens a compact native popover
anchored to the menu-bar icon. Click its AVRoutePickerView to select a receiver.
The picker uses the same AVPlayer as radio. The popover closes when Apple's
receiver list dismisses; clicking away closes an idle popover.

Opening the receiver list changes the radio's Output to **System Default** so a
fixed physical UID cannot pin playback elsewhere. This preference persists even
if selection is cancelled. Merely opening the popover does not change Output.

AVRouteDetector supplies only the **routes available** hint. Discovery is scoped
to menu/popover use. Receiver names and activation belong to Apple's picker;
CoreAudio enumeration and Refresh Outputs do not discover nearby AirPlay
receivers. Some receivers shown by macOS are absent from public CoreAudio
enumeration and therefore cannot be direct Output entries.

For external routing, choose Output → System Default before selecting a receiver
in macOS Sound/Control Center. Radio followed the system-selected receiver and
returned to speakers in development testing. The native-picker path was also
verified after media-control registration: radio was audible on the receiver,
Music stayed closed, and the app logged a successfully handled Play command.
The external system-selector path has not been separately retested after that
registration change. Receiver selection, availability and continuity depend on
macOS and the receiver; a detector flag or requested UID is not proof of sound.

Discovery has varied during testing, including receivers disappearing from
macOS's own AirPlay list. A working local-network/system discovery path is
required; Refresh Outputs cannot restore system AirPlay discovery.

## Recovery and resource use

Player/item observations and failure, end, stall and error-log notifications
trigger updates. A five-second timer checks waiting/progress and retry cooldown:

- 12-second startup grace for watchdog state checks.
- 30 seconds of continuous waiting or stalled playback progress.
- 30-second minimum spacing between automatic retries, retained across retries.
- Immediate initial retry on item failure or unexpected stream end.
- Manual station selection resets recovery; Pause and Stop prevent it.

No-progress detection requires playback time to have advanced first. Known
unsupported-format/decoder errors show a status instead of looping. Less specific
server/container errors may follow the normal retry policy.

Sleep releases the item but retains the station; wake reconnects unless paused
or stopped. Stop during sleep prevents wake playback. Quit, normal logout
termination and SIGTERM/SIGINT/SIGHUP release playback and disable recovery.
There is no owned external process to orphan.

The 10-second `preferredForwardBufferDuration` is a buffering preference, not a
memory cap; AVFoundation controls buffering, decoding and resource use.

## Streams and HTTP

Stations accept direct HTTP/HTTPS streams; HLS is not required. Playability
depends on AVFoundation's codec/container support, response headers, redirects
and live-stream behavior. A valid URL or successful HTTP response does not prove
playable audio. No decoder fallback is provided.

`NSAllowsArbitraryLoadsForMedia` permits configured HTTP media through
AVFoundation while retaining normal ATS policy for other networking. HTTP radio
is unencrypted; prefer HTTPS where available.

## Logs

**Show Logs** opens `~/Library/Logs/MPV Radio Tray/`. `radio.log` records station
labels, playback/recovery state, failure domain/code, media commands, output
inventory/filter reasons, route availability/presentation and lifecycle events.
It rotates around 512 KiB, retaining `radio.previous.log`. Station URLs,
credentials, device UIDs, network addresses and raw stream error text are not
written by the app. Friendly device names, UID presence, output channels,
transport and availability are logged when inventory changes. Apple framework
diagnostics may also appear in Console.

## Automated checks

From the repository root:

```sh
./macos/scripts/check.sh
./macos/scripts/check.sh --outputs
./macos/scripts/check.sh --popover
./macos/scripts/check.sh --stream https://netradio.live24.gr/galaxy9292
./macos/scripts/check.sh --stream https://stream.radiojar.com/redfm963
python3 macos/scripts/test-app-startup.py "macos/dist/MPV Radio Tray.app"
```

The default checks cover parsing, playback intent/recovery and output models
without network audio or Xcode/XCTest. Native modes require a logged-in macOS
graphical session. `--outputs` also checks real CoreAudio inventory, isolated
preferences, injected device changes and AVPlayer nil/concrete UID mapping
with a stopped player. `--popover` additionally opens/closes the native host
twice and simulates presentation delegates to verify shared-player ownership,
System Default preparation and dismissal; it never opens Apple's receiver list.

`--stream URL` loads muted radio on the built-in output when available, waits
up to 45 seconds for time to advance, and checks recovery, station switching,
output retention, deliberate pause through watchdog/sleep/wake/reconnect,
Now Playing metadata and Play/Pause/Toggle/Stop handling. Commands are invoked
directly in this harness; actual system command delivery needs a manual check.
The native checks confirm unchanged global output and no new Music process.
They never select AirPlay receivers or automate Music.

The startup check runs the actual signed application stopped and verifies clean
SIGTERM/SIGINT/SIGHUP shutdown. Temporary executables/caches are removed after
testing; application logs are retained. Build again with `build-app.sh` to check
the optimized application with warnings treated as errors.

### Manual acceptance

1. Open the installed Applications copy. Confirm the radio menu icon, station
   menu and stopped startup, with no Dock icon.
2. Play a station, listen, switch to another station and listen again. Stop;
   confirm silence. Quit while playing and confirm silence; reopen and confirm
   stopped startup.
3. Confirm physical outputs work and virtual software outputs are excluded.
   Check unplug/reconnect, unavailable state, and Stop preventing later resume.
4. While radio plays and Music is closed, select one AirPlay receiver manually.
   Confirm sound there and Music staying closed. `Media command: play; result=0`
   confirms command handling; listening confirms routing. Return to speakers.
5. With Output = System Default, separately try the system route selector and
   record sound, continuity and whether Music opens.
6. Check sleep/wake, Pause/Resume, network interruption/recovery and Quit/logout.
   Stop must survive wake and output reconnect.
7. Edit/reload malformed then valid stations; the last valid menu must survive
   an error. Do not infer physical routing from menu state alone.

Deployment targets macOS 13+, but runtime validation on other macOS releases,
Mac architectures and receivers is still required. No private APIs or third-party
packages are used.
