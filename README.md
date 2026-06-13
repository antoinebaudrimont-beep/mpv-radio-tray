# mpv Radio Tray

Lightweight GTK tray application for streaming live radio on Linux. Uses `mpv`
as the playback backend with automatic stream recovery, Bluetooth audio output
support, and custom station configuration.

Tags: `mpv`, `radio-player`, `gtk`, `tray-application`, `streaming`, `linux`,
`xfce`, `audio-player`, `python`, `multimedia`

**Tags:** `#mpv` `#radio-player` `#gtk` `#tray-application` `#streaming` `#linux` `#xfce`

## Install dependencies

```bash
sudo apt install mpv python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 bluez pulseaudio-utils
```

## Install locally

```bash
mkdir -p ~/.local/bin ~/.config/mpv-radio-tray ~/.local/share/applications
cp mpv-radio-tray ~/.local/bin/mpv-radio-tray
cp stations.txt ~/.config/mpv-radio-tray/stations.txt
cp mpv-radio-tray.desktop ~/.local/share/applications/mpv-radio-tray.desktop
chmod +x ~/.local/bin/mpv-radio-tray
```
### Create an XFCE launcher

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

## Stations

Edit:

```text
~/.config/mpv-radio-tray/stations.txt
```

Use one station per line:

```text
Station name|https://example.com/stream
```

For RadioJar streams, keep the clean URL rather than redirected token URLs.

## Output

Use the tray menu's `Output` submenu to switch between the computer's normal
audio sink and Bluetooth devices known to `bluetoothctl`.

Bluetooth devices must already be paired or otherwise listed by:

```bash
bluetoothctl devices
```

When you choose a Bluetooth device, the app asks `bluetoothctl` to connect to it,
waits for the matching audio sink, then tells `mpv` to use that sink. The same
output is reused when the current station is restarted.

## Recovery behavior

The app launches mpv with a private IPC socket and checks it every five
seconds. If mpv reports `paused-for-cache` for 35 seconds, exits, reaches EOF,
stops responding through IPC, or reports playback time that moved and then
stalled for 60 seconds, the tray app restarts the same station.

The tray process is not restarted, so the selected station is preserved.
