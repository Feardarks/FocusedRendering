# Engineering notes

Working notes for Focused Rendering. See [README.md](README.md) for what the
project is.

## Why the project pivoted

It began as a screen-capture streamer: capture a game window, foveate the
encode, send it to the headset. That was the wrong shape, for two reasons.

**Foveated streaming is not foveated rendering.** Compressing an
already-rendered frame according to gaze saves bandwidth. It does not save the
GPU any shading work, because every pixel was already shaded. Nothing outside a
third-party game's renderer can change what that renderer shades.

**Mac Virtual Display already does foveated streaming**, using real gaze, with
privileged system access, for free. For a flat game window, a userland
capture-and-encode streamer is strictly worse.

So the content source moved: instead of capturing someone else's frames, the Mac
renders its own, and the focus region drives an `MTLRasterizationRateMap` before
anything is shaded. That is the one architecture where gaze genuinely reduces
GPU work on the Mac — and it only works for content the renderer controls.

M0 survived the pivot untouched; only the source of frames changed.

## Benchmark findings

`fr-bench` on an Apple M2 Pro, 3660×3200, fragment-bound raymarched scene:

- Savings track pixel count almost exactly, and hold within a percentage point
  across a 3× sweep of shader cost (48/96/160 march steps). The result is
  therefore a property of the rate map, not of one scene.
- `aggressive` (middle 12% at full rate, 0.30 at the edges) cuts 47% of GPU time.
- This is an upper bound. The scene is entirely fragment-bound; vertex,
  geometry and draw-call cost does not shrink.

### Watch the normalization

The rate arrays are indexed by cell centre in 0...1, so a centred gaze is at most
**0.5** from either edge. Normalizing the falloff against 1.0 instead of that
half-extent silently caps every profile around two thirds of the way down: the
first run showed `extreme` cutting only 14% of pixels instead of 54%. The
benchmark looked like it worked and quietly reported a number that would have
killed the project at its own gate.

### Measure the steady state, not the keyframe

Encoding a single frame per path measures an I-frame and leaves the bitrate
ceiling doing nothing: the first run reported 143 KB/frame, which at 90 fps is
~105 Mbps against a nominal 50 Mbps cap. `fr-pipeline --bitrate` now encodes a
30-frame animated sequence and averages everything after the opening keyframe,
which drops the steady state to 10-12 KB/frame and lets rate control engage.

The reference has to be rendered at the *last* frame's scene time, not the
sequence's start, or the comparison measures the animation instead of the codec.

### Bandwidth is where foveation pays most

At 50 Mbps this scene never saturates the encoder, so both paths sit near their
rendering quality and the win is mostly in encode and decode time (29→18 ms and
9→6 ms). Squeeze the link and the picture changes completely: at 4 Mbps the
foveated path is 10.7 dB better in the fovea *and* 5.4 dB better in the worst
peripheral tile, because spreading a small budget across 11.7 Mpx degrades the
entire frame.

Worth remembering when reading these numbers: this scene is cheap for an encoder
relative to its resolution. Content with more motion would saturate a link
sooner, which moves the realistic operating point toward the constrained regime
where foveation wins by more.

### Overlapping render and encode, and what it did not fix

The loop used to render, wait for the encoder, send, and only then start the
next frame: 21 ms plus 31 ms is 52 ms, which was exactly the 17.4 fps measured.
Rendering now submits without waiting and the encoder delivers on its own
thread, with a semaphore admitting two frames at a time. Throughput is the
larger of the two stages instead of their sum:

|  | before | after |
|---|---|---|
| throughput | 17.4 fps | 49.4 fps |
| latency, median | 49.2 ms | 40.7 ms |
| latency, p95 | 69.0 ms | 42.1 ms |

The p95 is the more interesting column. Throughput nearly tripled, but a single
frame still passes through render *and* encode, so per-frame latency only fell
by the slack that had been sitting in the old loop. **Pipelining buys throughput,
not latency.** Cutting the remaining 40 ms means a cheaper scene, a lower
resolution or a faster encode — not more overlap.

Backpressure matters as much as the overlap. Without the semaphore the loop
would render faster than the encoder drains and latency would grow without
bound; two frames in flight is enough to keep the GPU and the media engine both
busy without queuing stale video.

### The encode size must not depend on where you look

A compression session is fixed to its dimensions, so a physical size that moves
with the gaze rebuilds the encoder — and emits a keyframe — every time the eye
does. It moved by 26%: 2108 to 2656 pixels wide across the screen.

Two fixes, because one was not enough:

1. **Normalize the rate budget.** An off-centre gaze puts more of the axis past
   the falloff, which lowers the mean rate. The rates are now blended toward
   full quality by a closed-form factor that lands exactly on the centred mean,
   so the budget is constant and the spare capacity goes to the periphery. That
   took the variation from 26% to 3.6%.
2. **Allocate against a sampled maximum.** Metal rounds each cell independently,
   so the total still depends on the distribution and no single gaze is reliably
   largest — the centred one was exceeded by four pixels at the diagonals.
   Everything is now sized against a sampled maximum plus a granularity step,
   and the client crops using the physical size in the rate map message.

Verified from the client: 486 frames carried 9 keyframes, which is exactly the
periodic interval, and one parameter-set message.

### PSNR needs a worst case, not an average

Peripheral PSNR averaged over the whole frame reads about 49 dB for every
profile, including the most aggressive. That number is meaningless here: most of
a frame is background that undersampling leaves bit-identical, and it drowns the
regions that were actually damaged. Per-tile worst case tells the real story —
around 35 dB, and roughly flat across profiles.

That flatness is the useful finding. Worst-case quality barely changes from
`balanced` to `extreme` while the GPU saving goes from 36% to 54%, which argues
for the aggressive end of the range.

### The test scene needed high-frequency detail

The first version of the scene was smooth gradients, which survive
undersampling nearly intact. It measured GPU time correctly and quality
misleadingly. Surfaces now carry a fine procedural pattern so the periphery has
something to lose.

### Separable, not radial

Metal's rate map is separable — one array for columns, one for rows — so the
full-quality region is a rounded rectangle, not a disc. Apple's own foveation
works the same way. There is no way to express a true radial fovea.

## Protocol

Reconstructed from Apple's documentation and its Windows reference endpoint
(`apple/StreamingSession`, MIT).

- **Discovery** — Bonjour `_apple-foveated-streaming._tcp`, TXT record
  `Application-Identifier` naming the visionOS app's bundle ID. Without a
  matching bundle ID the device will not connect.
- **Framing** — 4-byte unsigned little-endian length, then UTF-8 JSON.
- **Device → endpoint** — `RequestConnection`, `RequestBarcodePresentation`,
  `SessionStatusDidChange`.
- **Endpoint → device** — `AcknowledgeConnection`,
  `AcknowledgeBarcodePresentation`, `MediaStreamIsReady`,
  `RequestSessionDisconnect`.
- **Provider selection** — `RequestConnection` names the provider it wants as a
  reverse-DNS string; `com.nvidia.CloudXR` is the built-in one. A custom
  identifier is how a non-CloudXR endpoint is addressed.
- **Pairing** — omitting `CertificateFingerprint` from `AcknowledgeConnection`
  forces a re-pair. The QR code carries `{"token": …, "digest": …}` at error
  correction level L.
- **Session states** — `WAITING`, `CONNECTING`, `CONNECTED`, `PAUSED`,
  `DISCONNECTED`. `PAUSED` (device doffed) drops TCP but keeps the session
  alive; the endpoint must stay running for the reconnect.

Two details came from the reference endpoint rather than the documentation: the
QR payload's key spelling, and the shape of `BarcodePayload`.

## Entitlements

`com.apple.developer.foveated-streaming-provider` is approval-gated:

> Use of this entitlement requires Apple approval; complete the entitlement
> request form.

Request form:
https://developer.apple.com/contact/request/foveated-streaming-provider/

It is restricted, so it cannot be used in a development build either — an
approved provisioning profile is the only way in.

With approval, a `FoveatedStreamingExtension` appex (visionOS 27+) receives:

```swift
context.latestFocusRegion          // FoveatedStreamingProviderFocusRegion?
    .direction   // simd_float3 — gaze direction, device-relative
    .distance    // Float — estimated focal distance in metres
    .timestamp
```

Not approval-gated, and useful before then:

- `com.apple.developer.low-latency-streaming` — "intended for applications
  consuming streamed game content on visionOS"
- `com.apple.developer.foveated-streaming-session` — client side, visionOS 26.4

## Layout

```
Sources/
  FoveatedStreamingProtocol/   Messages, framing, session state machine — no I/O
  FoveatedStreamingHost/       Bonjour + TCP transport, QR rendering
  FoveationBenchmark/          Rate map construction, heavy scene, GPU timing
  FoveatedPipeline/            Inverse warp, HEVC round trip, image metrics
  fr-host/                     Streaming endpoint CLI
  fr-bench/                    GPU timing CLI
  fr-pipeline/                 Quality and codec CLI
Tests/                         Conformance, state machine, TCP loopback, profiles
```

The state machine is a pure function from message to actions, so the whole
handshake is testable without a socket. `LoopbackHandshakeTests` then drives the
real host over a real socket with a simulated headset.

Two tests are worth knowing about:

- **Framing conformance.** The documented example `{ "ClientID": "1234-5678-9ABC-DEF0" }`
  is exactly 37 bytes with prefix `25 00 00 00`, which pins the prefix's width,
  signedness and endianness in one assertion.
- **Absent is not null.** Omitting `CertificateFingerprint` requests a re-pair;
  sending null does not. The test checks that distinction survives encoding.

## Verifying the advertisement

```
dns-sd -B _apple-foveated-streaming._tcp local
dns-sd -L "Focused Rendering" _apple-foveated-streaming._tcp local
```

## Open questions

1. **Certificate fingerprint.** `DevelopmentCredentials` returns a placeholder.
   Pairing completes, but the device will refuse the media stream until this is
   the SHA-256 digest of the real TLS certificate. Blocks M1.
2. **Client token semantics.** Apple's endpoint gets the token from CloudXR's
   `NvStreamManager`. For a custom provider the token is presumably ours to
   define, since our own extension validates it — unverified.
3. **Media transport.** How the device opens the stream after `MediaStreamIsReady`
   is CloudXR-internal. A custom provider defines its own, which is exactly the
   part the entitlement gates.
4. **Pairing store.** `knownFingerprint` always returns nil, so every session
   re-pairs. Persisting it removes the QR step.
5. **Rate map churn.** A sweeping focus rebuilt the map on 16% of frames, and
   each rebuild resends the full parameter block. The threshold trades fovea lag
   against rebuild cost and has not been tuned against real gaze, only against a
   synthetic circle.
6. **Latency of the gaze loop.** The focus region reaches the Mac one round trip
   late, so the rate map always trails the eye. Post-saccade the fovea lands
   outside the high-rate region for a frame or two. Whether that is visible, and
   whether enlarging the full-quality region to cover the landing zone is enough,
   is the open question M3 has to answer.

## Sources

- Establishing foveated streaming sessions with Apple Vision Pro — Apple Developer
- FoveatedStreamingExtension, FoveatedStreamingProviderFocusRegion — Apple Developer
- com.apple.developer.foveated-streaming-provider — Apple Developer
- apple/StreamingSession — Windows reference endpoint (MIT)
- Use foveated streaming to bring immersive content to visionOS — WWDC26 session 286

Apple's DocC pages are JavaScript-rendered; fetch
`https://developer.apple.com/tutorials/data/documentation/<path>.json` instead.
