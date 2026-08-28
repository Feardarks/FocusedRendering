# Engineering notes

Working notes for Focused Rendering. See [README.md](README.md) for what the
project is.

## What this does not do

**It does not reduce the GPU cost of rendering the streamed content.** A
third-party title renders every pixel at full resolution regardless of where the
user looks; nothing outside its renderer changes that. Adding capture, warp and
encode makes the Mac's total GPU load slightly *higher*.

The payoff is foveated *encoding*: fewer pixels compressed and transmitted, so a
sharper image at a given bitrate and lower latency. Worth re-reading before
adding scope — the distinction is easy to lose.

The original motivation was streaming Death Stranding from an M2 Pro MacBook Pro
at ultrawide resolutions, where Mac Virtual Display's compression is the limiting
factor rather than the GPU.

## Kill gate

If M1 is not visibly better than Apple's own Mac Virtual Display, stop. Mac
Virtual Display has privileged system access and real gaze foveation; a userland
streamer beating it is not a given.

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
  fr-host/                     CLI
Tests/                         Conformance, state machine, TCP loopback
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

## Sources

- Establishing foveated streaming sessions with Apple Vision Pro — Apple Developer
- FoveatedStreamingExtension, FoveatedStreamingProviderFocusRegion — Apple Developer
- com.apple.developer.foveated-streaming-provider — Apple Developer
- apple/StreamingSession — Windows reference endpoint (MIT)
- Use foveated streaming to bring immersive content to visionOS — WWDC26 session 286

Apple's DocC pages are JavaScript-rendered; fetch
`https://developer.apple.com/tutorials/data/documentation/<path>.json` instead.
