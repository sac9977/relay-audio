# Relay

**Any app → every speaker.** Relay is a native macOS audio streamer in the spirit of Rogue Amoeba's Airfoil: it captures the audio of any running app with a Core Audio process tap and fans it out to Bluetooth, AirPlay, USB, and network receivers — in a sync group, so multiple speakers stay phase-coherent.

> Requires **macOS 14.4+** (Core Audio process taps, the same API Airfoil 5 uses). Built with Swift 5.9+ and SwiftUI. No third-party dependencies.

## Features

- **Any-app capture** — pick any running process as the source via Core Audio process taps (`AudioHardwareCreateProcessTap`); live list with app icons and "playing" badges
- **Fan-out to every output** — Bluetooth, AirPlay receivers, USB/HDMI, and the Mac itself, each with independent enable/mute/volume
- **Sync group** — one shared capture clock; per-sink drift control (±0.9 % chunk modulation) keeps speakers phase-locked; live **sync scope** charts each output's offset vs the clock
- **Per-speaker delay trim** — 1 ms-step compensation for fixed Bluetooth transport skew
- **Low-latency mode** — ~60 ms path for video lip sync vs ~300 ms whole-house mode
- **Silence Monitor** — auto-stop after 1–30 min of quiet source
- **Live device tracking** — HAL listeners attach/detach sinks as devices appear and vanish, mid-stream
- **Relay Satellite** — a companion receiver app for other Macs: raw Float32 PCM over UDP (bit-exact, no codec), NACK-based resend, loss concealment
- **Menu bar mode**, per-output health stats, persisted preferences

## Build

```bash
git clone https://github.com/sac9977/relay-audio.git
cd relay-audio

# Main app (dist/Relay.app)
./build_app.sh

# Satellite receiver (dist/Relay Satellite.app)
./Scripts/build_satellite.sh
```

Requirements: Xcode with the macOS 14.4+ SDK (built and tested on macOS 15+ / Apple Silicon).

## Running

1. Launch `dist/Relay.app`
2. Pick a source app that's playing audio, tick outputs, press **Start Streaming**
3. Grant the **Audio Recording** permission when macOS asks (once)

The first capture triggers the TCC prompt; if you deny it, taps deliver silence — re-enable under System Settings → Privacy & Security → Audio Recording.

### Bluetooth treble tip

macOS negotiates a conservative SBC bitpool. Relay's development found raising it helps:

```bash
defaults write com.apple.BluetoothAudioAgent "Apple Bitpool Min (editable)" -int 48
defaults write com.apple.BluetoothAudioAgent "Apple Bitpool Max (editable)" -int 64
defaults write com.apple.BluetoothAudioAgent "Negotiated Bitpool Min" -int 48
defaults write com.apple.BluetoothAudioAgent "Negotiated Bitpool Max" -int 64
```

…then reconnect the speaker. Revert with `defaults delete com.apple.BluetoothAudioAgent`.

## Architecture

```
┌────────────┐   process tap    ┌───────────────┐  rings  ┌──────────────┐
│ Music.app  │ ───────────────▶ │ CaptureEngine │ ──────▶ │ SinkEngine   │──▶ Bluetooth/AirPlay/…
│ (any app)  │  CATap + agg     │ (IOProc, one  │         │ (AVAudioEngine│
└────────────┘  device          │  producer     │         │  per output,  │
                                │  clock)       │         │  drift ctrl)  │
                                └───────────────┘         └──────────────┘
                                        │                        ▲
                                        │ rings                  │ UDP raw PCM
                                        ▼                        │
                                ┌───────────────┐         ┌──────┴─────────┐
                                │ NetworkSink   │ ──────▶ │ RelaySatellite │
                                │ (NACK resend) │         │ receiver app   │
                                └───────────────┘         └────────────────┘
```

- **`Sources/Relay/Core`** — process-tap capture, device/process scanning, sync-group sink engines, network sender
- **`Sources/SatelliteKit`** — shared ring buffer + UDP wire protocol (`RLR1` packets, NACK resend)
- **`Sources/RelaySatellite`** — the receiver app (jitter buffer, loss concealment, playback)
- **`Sources/Relay/UI`** — SwiftUI interface, controller, menu bar panel

### Design notes

- Capture runs through a private aggregate device; the tap is stereo mixdown of one process, unmuted by default (optional "mute source locally" uses `CATapMutedWhenTapped`)
- Sinks pre-roll ~300 ms before playing, then hold that latency against the producer clock — consumption starting *behind* the producer can never catch up (a bug we hit and fixed; see `SinkEngine.prerolled`)
- Drift between crystals is absorbed by chunk-size modulation, not resampling — ±512 frames every few seconds is inaudible; overflow/underrun is not
- Network transport is deliberately lossless (raw float PCM); NACKs repair Wi-Fi packet loss within the jitter budget

## Status

Working personal project — expect rough edges. Known gaps: AirPlay/Chromecast protocols aren't implemented directly (devices must already exist as system outputs), no Bonjour auto-discovery for Satellite yet, iOS receiver not started.

## License

MIT — see [LICENSE](LICENSE).
