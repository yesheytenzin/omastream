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
Defaults follow OBS Studio's service definitions:
  - **Twitch**: anycast RTMPS ingest (`rtmps://ingest.global-contribute.live-video.net/app`) —
    Twitch's CDN routes you to the nearest POP. Or click **PICK FASTEST INGEST**
    in the panel to pull the recommended one from Twitch's ingest feed.
  - **YouTube**: RTMPS primary `rtmps://a.rtmps.youtube.com:443/live2`
    (backup: `rtmps://b.rtmps.youtube.com:443/live2?backup=1`)
  - **X**: regional Producer ingest `rtmp://<region>.pscp.tv:80/x` —
    regions: ca, or, va, br, fr, ie, de, au, in, jp, kr, sg

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
each platform gets its own process with that service's recommended encoder
settings (keyframe interval, audio bitrate):

```
gpu-screen-recorder -w screen -f 60 -a default_output \
  -k h264 -c flv -ac aac -bm vbr -q medium \
  -keyint 2 -ab 160 \
  -o rtmps://ingest.global-contribute.live-video.net/app/<key>
```

Per-service recommendations (from OBS's services.json):
Twitch keyint=2s / audio≤160 · YouTube keyint=2s / audio≤160 ·
X keyint=3s / audio≤128 / max 60fps.

Stopping kills all of them. If one exits unexpectedly, the error surfaces in
the panel while the others keep running.

## License

MIT
