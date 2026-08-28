# Focused Rendering

Gaze-driven foveated **rendering** on a Mac, streamed to Apple Vision Pro.

## Purpose

Apple Vision Pro knows where the wearer is looking. A Mac rendering content for
it does not, so it shades every pixel at full rate — including the periphery,
where the eye cannot resolve the detail.

Focused Rendering closes that loop. The headset's focus region drives a Metal
rasterization rate map on the Mac, so the Mac's GPU shades fewer pixels where
they cannot be seen. This is foveated rendering, not foveated compression: the
saving happens before a frame exists, in the renderer.

It is an independent, open-source project by a single developer, built against
Apple's published Foveated Streaming documentation.

```mermaid
flowchart LR
  subgraph s1[Without the focus region]
    A1[Shade every pixel at full rate] --> A2[11.7 Mpx] --> A3[57 ms GPU]
  end
  subgraph s2[With the focus region]
    B1[Shade at variable rate] --> B2[6.2 Mpx] --> B3[30 ms GPU]
  end
```

## Measured

Real GPU time on an Apple M2 Pro, rendering a fragment-bound raymarched scene at
3660×3200 — Apple Vision Pro's per-eye resolution. `fr-bench` reproduces this.

| Profile | Pixels shaded | GPU time | Saved |
|---|---|---|---|
| off (baseline) | 11.7 Mpx | 56.9 ms | — |
| conservative | 8.9 Mpx | 43.4 ms | 24% |
| balanced | 7.6 Mpx | 36.6 ms | 36% |
| aggressive | 6.2 Mpx | 30.0 ms | 47% |
| extreme | 5.4 Mpx | 26.2 ms | 54% |

The saving holds steady across a 3× sweep of shader cost, so it is driven by
pixel count rather than by one scene's particulars. This is an upper bound:
fully fragment-bound work benefits most, while vertex, geometry and draw-call
cost does not shrink.

## How it works

```mermaid
flowchart LR
  subgraph s3[Apple Vision Pro]
    EYE[Eye tracking, system-owned] --> PROV[Provider extension]
    DEC[Decode] --> DISP[Display]
  end
  subgraph s4[The user's own Mac, same local network]
    RATE[Build rasterization rate map] --> REND[Render fewer pixels] --> ENC[Encode]
  end
  PROV -->|coarse focus region| RATE
  ENC -->|video| DEC
```

The Mac advertises itself over Bonjour as `_apple-foveated-streaming._tcp` and
completes the session-management handshake and QR pairing. Once streaming, the
provider extension quantizes the focus region and passes it to the Mac, which
centres its rate map there for the next frame.

## Privacy

Both endpoints are devices the user already owns, talking directly to each other
over the user's own local network.

- **No third party.** No server, no cloud relay, no analytics endpoint. This
  project operates no infrastructure, and makes no outbound connection other
  than the direct peer-to-peer link to the paired headset.
- **No accounts, no telemetry, no crash reporting, no identifiers.**
- **The focus region never leaves the streaming session.** It steers the rate
  map and the encoder, nothing else. It is never exposed to any other
  application, never written to disk, never logged, and discarded once the frame
  it steered has been rendered.
- **Only a coarse region crosses the link**, quantized to the rate map's cell
  grid — not raw gaze vectors, and not at a fidelity that would reconstruct
  them.
- **Pairing is explicit and mutual.** A session requires a QR code scanned on
  the headset, and the endpoint is reachable only on the local network.
- **Auditable.** The source is public. Every claim above is verifiable by
  reading it rather than taken on trust.

## Entitlement

Reading the focus region requires `com.apple.developer.foveated-streaming-provider`,
which is what this project is requesting.

To be explicit about the scope: the built-in provider uses the focus region to
steer video encoding. This project also uses it to steer rasterization on the
host, which is where the measured savings above come from. Both stay inside the
streaming session, and neither surfaces the data to anything else.

The session-management protocol, pairing and the rate-map renderer are already
implemented and tested without the entitlement.

## Status

| Milestone | Scope | State |
|---|---|---|
| M0 | Discovery, pairing handshake, session state | **complete** |
| M1 | Rate-map renderer and GPU measurement | **complete** |
| M2 | Encode, transport and display, driven by head pose | next |
| M3 | Driven by the focus region | requires the entitlement |

M2 substitutes head pose for gaze, so the full pipeline can be validated before
the entitlement exists.

## Building

```
swift build
swift test

fr-bench                                    # reproduce the measurements
fr-host --bundle-id <visionOS app bundle ID>  # run the streaming endpoint
```

Requires macOS 14 or later and an Apple silicon Mac. Engineering notes, protocol
details and open questions are in [NOTES.md](NOTES.md).

## License

MIT
