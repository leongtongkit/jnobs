# Jnobs

A macOS menu-bar app for the [Turn Up](https://turnup.tech) hardware volume mixer.

> **Not affiliated with turnup.tech.** Jnobs is an independent, community-built
> macOS application for the Turn Up mixer. It is not produced, endorsed,
> sponsored, or supported by turnup.tech. "Turn Up" is referenced only to
> identify the hardware Jnobs controls.

The official Turn Up software is Windows-only and no longer maintained.
Jnobs is a from-scratch macOS replacement, written natively in Swift with
no dependencies on the vendor's software.

## Features

### Knobs
Bind each of the five knobs to any of:
- **System volume**
- **Microphone input level**
- **Volume of a specific app** (per-app gain, independent of system volume)
- **Display brightness**

### Buttons
Bind each of the five buttons — with separate **short-press** and
**long-press** actions — to any of:
- Play / Pause / Next / Previous (media keys)
- Toggle system mute
- Toggle microphone mute
- Spotify shuffle / repeat
- Arbitrary shell commands

### Lighting
- Per-knob LED color, with several modes (solid, position-fill, breathing).
- Live on-screen LED mirror in the Console window.
- **LED VU meter** — when a knob controls an app's volume, its LED ring
  tracks the live audio level of that app.

### Profiles
- Save the entire binding set as a named profile.
- Switch profiles instantly (gaming / music / work, etc.).
- **Update** a saved profile in place (no need to delete and re-save).
- Delete profiles you no longer need.

### Per-app audio routing
Send a specific app's audio to a specific output device — for example,
keep your music on speakers while routing your meeting audio to headphones.
Built on macOS's public process-tap API; no third-party audio drivers
required.

### Microphone auto-mute
Optional automatic mic muting when you're not speaking. Detects silence
with hysteresis so it won't chop the start of your words.

### Stream Deck integration
The bundled Stream Deck plugin lets you control Jnobs from an Elgato
Stream Deck:
- Switch directly to a named profile (with live active-state highlight)
- Cycle to the next / previous profile
- Toggle microphone mute
- Fire any of the five hardware buttons

### Other
- **Live HUD** — a small overlay shows the current value when you turn a knob.
- **Smart menu-bar icon** — reflects volume level, mute state, and connection.
- **Console window** — live view of all hardware state, plus configuration
  for every binding, plus diagnostics.
- **Launch at login**.
- **Robust to hotplug, sleep, wake, and device hot-swap.**

## Install

### Download a pre-built release (recommended)

Grab the latest signed and notarized build from the
[**Releases** page](https://github.com/leongtongkit/jnobs/releases/latest):

1. Download `Jnobs.zip`.
2. Unzip — you get `Jnobs.app`.
3. Drag `Jnobs.app` to your **Applications** folder.
4. Double-click to launch.

If macOS shows a Gatekeeper warning the first time, right-click the app and
choose **Open** → **Open** to confirm. (You only need to do this once; after
that the app launches normally.)

### Build from source

Requires macOS 15+ and Xcode command-line tools.

```bash
git clone https://github.com/leongtongkit/jnobs.git
cd jnobs/app
./build_app.sh --release --install --run
```

This builds, code-signs (ad-hoc), installs to `~/Applications/Jnobs.app`,
and launches it.

### First run

The first time per-app audio routing is used, macOS will prompt for
**Audio Recording** permission — grant it. (The process-tap API is gated
behind this permission system-wide.)

### Stream Deck plugin (optional)

1. Enable Stream Deck developer mode:
   `defaults write com.elgato.StreamDeck html_remote_debugging_enabled -bool true`
2. Symlink the plugin into Stream Deck's Plugins folder:
   `ln -s "$(pwd)/streamdeck-plugin/net.jfound.jnobs.sdPlugin" \
      ~/Library/Application\ Support/com.elgato.StreamDeck/Plugins/`
3. Restart Stream Deck. Jnobs actions appear under the **Jnobs** category.

## How the protocol was determined

Jnobs talks to the Turn Up mixer over its USB CDC-ACM serial interface
using a protocol that was **clean-room reverse-engineered** by observing
USB byte streams from the device. The probe scripts used to do this
(and a methodology note) live in [`probe/`](probe/). No vendor binaries
were inspected at any point.

The full protocol is documented in [`PROTOCOL.md`](PROTOCOL.md).

## License

Jnobs is released under the **GNU General Public License v3.0**. See
[`LICENSE`](LICENSE) for the full text.

Third-party assets (currently: the Lacquer font) are licensed separately;
see [`THIRD_PARTY_LICENSES.md`](THIRD_PARTY_LICENSES.md).
