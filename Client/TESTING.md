# Testing tonight

Two programs: `fr-host` on the Mac captures and streams, the visionOS app
receives and displays. They find each other over Bonjour on the same network.

## 0. Grant screen recording, once

Capture needs Screen Recording permission, and macOS attributes it to whichever
app launches the tool — usually Terminal. The first run raises the prompt; if
you miss it, add Terminal under **System Settings › Privacy & Security › Screen
Recording** and restart Terminal.

Nothing is captured until this is granted, and the host says so rather than
silently sending black frames.

## 1. Start the Mac side

```
cd /Users/emirhansanli/FocusedRendering
swift build -c release
./.build/release/fr-host --bundle-id com.emirhan.FocusedRendering.client --stream --capture
```

It should print the capture size and that the channel is secured. Leave it
running.

Useful flags:

- `--capture-fps 90` — upper bound. A display cannot be made to exceed its own
  refresh, so a 60 Hz external monitor caps you at 60 whatever this says. The
  MacBook Pro's own ProMotion panel is the one that can do 90+.
- `--capture-size 3360x1440` — capture smaller than the display. This is the
  main lever: encode throughput measured about 720 Mpx/s on M2 Pro, so 90 fps
  needs the frame under roughly 8 Mpx.
- `--profile off | conservative | balanced | aggressive | extreme` — trades
  peripheral resolution for encoder headroom. `off` while bringing this up;
  reach for it when the capture is too large for 90 fps.
- `--bitrate 60` — Mbps.
- Drop `--capture` to stream the synthetic test scene instead, which is useful
  for separating a capture problem from a streaming one.

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
