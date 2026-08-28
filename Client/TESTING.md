# Testing tonight

Two programs: `fr-host` on the Mac renders and streams, the visionOS app
receives and displays. They find each other over Bonjour on the same network.

## 1. Start the Mac side

```
cd /Users/emirhansanli/FocusedRendering
swift build -c release
./.build/release/fr-host --bundle-id com.emirhan.FocusedRendering.client --stream
```

It should print the media port and that the channel is secured. Leave it running.

Useful flags:

- `--profile conservative | balanced | aggressive | extreme` — how hard to
  foveate. Start at `aggressive`; drop to `balanced` if the periphery bothers
  you.
- `--bitrate 40` — Mbps.
- `--media-port 48011` — must match the port in the app.

## 2. Check the Mac side alone first

Before involving the headset, confirm the host works:

```
./.build/release/fr-probe --seconds 5 --sweep
```

Expect roughly 47 fps and no index gaps. If this fails, the headset will not
help — fix it here first.

## 3. Build and run the app

Open `Client/FocusedRenderingClient.xcodeproj`, select your team under Signing
& Capabilities, pick your Apple Vision Pro as the destination, and run.

The bundle identifier is `com.emirhan.FocusedRendering.client`, which is what
`--bundle-id` advertises. If you change one, change both.

## 4. In the headset

The window lists hosts found on the network. Tap yours. The status should go
from *Connecting* to *Streaming*, and the frame counter should climb.

Then tap **Open screen** to place the streamed panel in front of you.

## What to look at

The debug panel is the point of tonight. In order of importance:

**Encoded size vs rate map.** These two numbers must match. The host sends the
size it encoded at; the app rebuilds the rate map locally and reports what it
computed. If they disagree, the two GPUs rounded the map differently and the
image will be subtly stretched — that is the single most likely thing to be
wrong, and it shows up as a red number rather than as a mystery.

**Frames received vs decoded.** A gap means the decoder is rejecting frames.

**Focus.** Should track your head as you look around, roughly 0.5, 0.5 when
looking straight ahead. If it is pinned, head tracking did not start — check the
permission prompt.

**Frame rate and bitrate.** Compare against what `fr-probe` reported on the Mac.
A large drop is the wireless link, not the pipeline.

## Known limitations

- **The fovea follows your head, not your eyes.** That is the entitlement we do
  not have yet. Turning your head moves the sharp region; glancing without
  moving your head does not. So do not judge peripheral quality tonight — judge
  whether the picture arrives, holds together, and stays in sync.
- Latency in the panel is only meaningful when host and client share a clock,
  which they do not here. Treat it as relative.
- Pairing uses the derived secret rather than the QR code, so no camera step.
