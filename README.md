# oma-stream

Go live on **Twitch**, **YouTube**, and **X** in a single click — from your Omarchy bar.

One button starts a simulcast: oma-stream spawns one `gpu-screen-recorder`
process per enabled platform, pushing your screen + audio to every RTMP
ingest endpoint at once. No OBS scene required.

![kind: bar-widget] · category: Media

## Features

- **One-click simulcast** — start/stop Twitch, YouTube, and X together
- **Per-platform config** — enable/disable, ingest URLs, capture settings
- **Keys in the system keyring** — stream keys are stored via the Secret
  Service (`secret-tool` / gnome-keyring), never written to disk
- **Live indicator** — the bar widget shows `● LIVE mm:ss` while streaming
- **IPC control** — toggle streaming from scripts/keybinds

## Requirements

- [gpu-screen-recorder](https://git.dec05eba.com/gpu-screen-recorder/) (`pacman -S gpu-screen-recorder`)
  — hardware-encoded Wayland capture with audio mixing
- `libsecret` (provides `secret-tool`; gnome-keyring is already running on Omarchy)
- An RTMP ingest URL + stream key per platform:
  - **Twitch**: `rtmp://live.twitch.tv/app/` + your key (Dashboard → Settings → Stream)
  - **YouTube**: `rtmp://a.rtmp.youtube.com/live2/` + your key (youtube.com/live_dashboard)
  - **X**: paste the full ingest URL from X Live Studio / Media Studio producer

## Install

```bash
omarchy plugin add https://github.com/yaredow/omastream.git --enable
```

Or copy this folder to `~/.config/omarchy/plugins/user.omastream/`, then:

```bash
omarchy plugin enable user.omastream
omarchy-shell shell rescanPlugins
```

Add the widget to your bar layout (`right` section by default) via bar settings.

## Usage

1. Click the widget → panel opens
2. Toggle platforms, paste each stream key — it goes straight into the
   keyring (the field clears; the placeholder shows what's stored). Clear
   the field and commit to delete a key.
3. Pick FPS / quality / audio source
4. Hit **● GO LIVE — ALL PLATFORMS**

Platforms with no key on file are skipped (with a notice) so one missing
key never blocks the others.

### IPC

```bash
# start/stop all enabled platforms
qs ipc -p /usr/share/omarchy/shell call user.omastream toggleStream

# open/close the panel
omarchy-shell shell summon user.omastream '{}'
omarchy-shell shell hide user.omastream
```

## Configuration file

`~/.config/omastream/config.json`:

```json
{
  "fps": 60,
  "quality": "medium",
  "audio": "default_output",
  "capture": "screen",
  "twitch":  { "enabled": true,  "url": "rtmp://live.twitch.tv/app/" },
  "youtube": { "enabled": true,  "url": "rtmp://a.rtmp.youtube.com/live2/" },
  "x":       { "enabled": false, "url": "" }
}
```

No secrets here — deliberately. Stream keys live in your login keyring:

```bash
# inspect / delete manually
secret-tool lookup service omastream username twitch
secret-tool clear  service omastream username youtube
```

- `capture`: `"screen"` (all monitors), a monitor name (`gpu-screen-recorder --list-monitors`), `"portal"`, or `"focused"`
- `audio`: run `gpu-screen-recorder --list-audio-devices`; `"default_output"` = system audio

## How it works

At go-live, each enabled platform's key is fetched from the keyring, then
each platform gets its own process:

```
gpu-screen-recorder -w screen -f 60 -a default_output \
  -k h264 -ac aac -bm vbr -q medium \
  -o rtmp://live.twitch.tv/app/<key>
```

Stopping kills all of them. If one exits unexpectedly, the error surfaces in
the panel while the others keep running.

## License

MIT
