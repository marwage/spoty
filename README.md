# Spoty

A native macOS wrapper around [`spotify_player`](https://github.com/aome510/spotify-player),
so it can replace Spotify.app.

`spotify_player` is already a complete Spotify client — it embeds librespot, so it streams
and decodes audio itself rather than remote-controlling anything. What it lacks is a Mac
app's surface: no Dock presence, no Now Playing tile, no working media keys, and
notifications attributed to whichever terminal it happens to be running in.

This app supplies exactly that. It hosts the real TUI in a proper window (album art
included, via the Kitty graphics protocol) and implements the macOS integration natively:

- **Now Playing** in Control Centre and on the lock screen, with artwork and a scrubber
  that advances smoothly
- **Hardware media keys** and AirPods gestures
- **Track-change notifications** with real album art *(off by default)*
- **Menu bar item** with transport controls that work with the window closed *(off by default)*
- **Follows the system output device**, restarting librespot's audio engine when you
  connect AirPods — which it otherwise will not do

Spotify.app does not need to be installed or running.

## Requirements

- macOS 14 or later
- Swift 6 toolchain — Apple CommandLineTools is enough, **Xcode is not required**
- A Spotify **Premium** account (librespot requires it)
- `spotify_player`, authenticated at least once

## Install

```sh
brew install spotify_player
spotify_player            # run once to authenticate, then quit with `q`

git clone <this-repo> music-player
cd music-player
./Scripts/build-app.sh
open ~/Applications/Spoty.app
```

`build-app.sh` compiles the release binary, generates the icon, assembles the `.app`,
signs it ad-hoc, and installs it to `~/Applications`. Re-run it to update.

To install elsewhere:

```sh
INSTALL_DIR=/Applications ./Scripts/build-app.sh
```

## Settings

In the **Player** menu (and in the menu bar item, once enabled):

| Setting | Default | |
|---|---|---|
| Menu Bar Item | off | Now-playing line and transport controls in the menu bar |
| Track Change Notifications | off | Enabling it is what triggers the macOS permission prompt |
| Follow Output Device | on | Restarts the audio engine when the default output changes |

`Follow Output Device` works by sending the TUI's `RestartIntegratedClient` key binding,
since the control socket has no restart command. If a TUI text field has focus when your
output device changes, that keystroke types a literal `R` instead — which is why it can be
turned off.

## How it works

The app launches `spotify_player` as a child process inside an embedded terminal
([SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)) and talks to it over its UDP
control socket, on a dedicated port so it never collides with a `spotify_player` running
in your own terminal.

It launches the child with `-o` overrides rather than touching your
`~/.config/spotify-player/app.toml`, so terminal use is unaffected:

```
-o client_port=8974
-o enable_media_control=false     # handled natively here instead
-o enable_notify=false            # handled natively here instead
-o device.name=Spoty
```

Media control and notifications are disabled deliberately. `spotify_player`'s macOS media
control goes through `souvlaki`, which needs a window it does not have as a CLI, so it
opens an invisible one that steals focus on startup and leaves a ghost in the Dock. Its
notifications route through `mac_notification_sys`, which drops the artwork entirely. A
bundled app with a real run loop does both properly.

On startup the app claims Spotify playback for its own Connect device — otherwise commands
act on whatever device is currently active (a phone, another Mac) and no audio comes out of
this one.
