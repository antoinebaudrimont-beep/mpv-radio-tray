# mpv Radio Tray

Tiny GTK tray app for live radio streams on MX Linux Xfce. It uses `mpv` as
the playback backend and restarts only the `mpv` child process if a stream
buffers for too long, exits, or becomes idle.

## Install dependencies

```bash
sudo apt install mpv python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1
```

## Install locally

```bash
mkdir -p ~/.local/bin ~/.config/mpv-radio-tray ~/.local/share/applications
cp mpv-radio-tray ~/.local/bin/mpv-radio-tray
cp stations.txt ~/.config/mpv-radio-tray/stations.txt
cp mpv-radio-tray.desktop ~/.local/share/applications/mpv-radio-tray.desktop
chmod +x ~/.local/bin/mpv-radio-tray
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

## Recovery behavior

The app launches mpv with a private IPC socket and checks it every five
seconds. If mpv reports `paused-for-cache` for 35 seconds, exits, reaches EOF,
stops responding through IPC, or reports playback time that moved and then
stalled for 60 seconds, the tray app restarts the same station.

The tray process is not restarted, so the selected station is preserved.
