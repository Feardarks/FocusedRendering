import CoreVideo
import Foundation
import FoveatedPipeline
import FoveatedStreamingHost
import FoveatedStreamingProtocol
import FoveationBenchmark
import Metal

public struct StreamerConfiguration: Sendable {
    public var width = 3660
    public var height = 3200
    public var marchSteps = 96
    public var profile = FoveationProfile.aggressive
    public var bitsPerSecond = 40_000_000
    public var framesPerSecond = 90
    /// How far the focus point must move before the rate map is rebuilt.
    ///
    /// Rebuilding costs a map allocation and forces the client to reload it, so
    /// a threshold keeps ordinary micro-movement from thrashing both. Too large
    /// and the fovea lags the eye; this is roughly a third of the full-rate
    /// region.
    public var focusRebuildThreshold: Float = 0.04
    /// How many frames may be rendering or encoding at once.
    ///
    /// One means the serial behaviour this replaced. More overlap costs latency
    /// — a frame waits behind the ones ahead of it — so this stays small: enough
    /// to keep the GPU and the media engine both busy, not enough to build a
    /// queue of stale video.
    public var maxFramesInFlight = 2

    public init() {}
}

public struct StreamerStatistics: Sendable {
    public var framesSent = 0
    public var focusUpdatesReceived = 0
    public var rateMapGenerations = 0
    public var meanRenderMilliseconds = 0.0
    public var meanEncodeMilliseconds = 0.0
    public var meanBytesPerFrame = 0
}

/// Drives the loop: take the latest focus point, build a rate map around it,
/// render, encode, and put the frame on the wire.
public final class FoveatedStreamer: @unchecked Sendable {

    private let configuration: StreamerConfiguration
    private let device: any MTLDevice
    private let renderer: RoundTrip
    private let bridge: PixelBufferBridge
    private let link: MediaLink

    private let lock = NSLock()
    private var focus = SIMD2<Float>(0.5, 0.5)
    private var focusUpdates = 0

    private var rateMap: (any MTLRasterizationRateMap)?
    private var rateMapFocus = SIMD2<Float>(-1, -1)
    private var rateMapGeneration: UInt32 = 0

    /// A render target and the Core Video buffer it aliases.
    ///
    /// One per in-flight frame: the encoder reads a buffer after the render that
    /// filled it has completed, so a single buffer would have the next frame
    /// overwriting one still being compressed.
    /// Unchecked because ownership is enforced by the pipeline rather than the
    /// type: `inFlight` admits at most one frame per slot, and slots are handed
    /// out round-robin, so exactly one render and then one encode touch a given
    /// buffer before it is reused.
    private struct Slot: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let texture: any MTLTexture
    }
    private var slots: [Slot] = []
    private var nextSlot = 0
    private let inFlight: DispatchSemaphore
    private let encodeQueue = DispatchQueue(label: "com.focusedrendering.encode")

    private var codec: VideoCodec?
    private var codecSize = (width: 0, height: 0)

    private var frameIndex: UInt64 = 0
    private var framesSent = 0
    private var cachedAllocation: MTLSize?
    private var renderTimes: [Double] = []
    private var encodeTimes: [Double] = []
    private var frameSizes: [Int] = []

    private var running = false
    private var thread: Thread?

    public var onLog: (@Sendable (String) -> Void)?

    public init(configuration: StreamerConfiguration, link: MediaLink) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw BenchmarkError.noDevice }
        self.configuration = configuration
        self.inFlight = DispatchSemaphore(value: max(1, configuration.maxFramesInFlight))
        self.device = device
        self.renderer = try RoundTrip(device: device)
        self.bridge = try PixelBufferBridge(device: device)
        self.link = link
    }

    /// Records where the headset says the person is looking.
    ///
    /// Called from the network queue while the render loop reads it, so the
    /// value is guarded rather than assumed to be a torn-read-free `SIMD2`.
    public func updateFocus(_ update: FocusUpdate) {
        lock.lock()
        focus = SIMD2(update.x.clamped(), update.y.clamped())
        focusUpdates += 1
        lock.unlock()
    }

    public func start() {
        guard !running else { return }
        running = true
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "com.focusedrendering.streamer"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running = false
    }

    public var statistics: StreamerStatistics {
        lock.lock(); defer { lock.unlock() }
        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        return StreamerStatistics(
            framesSent: framesSent,
            focusUpdatesReceived: focusUpdates,
            rateMapGenerations: Int(rateMapGeneration),
            meanRenderMilliseconds: mean(renderTimes),
            meanEncodeMilliseconds: mean(encodeTimes),
            meanBytesPerFrame: frameSizes.isEmpty ? 0 : frameSizes.reduce(0, +) / frameSizes.count
        )
    }

    private func loop() {
        let frameDuration = 1.0 / Double(configuration.framesPerSecond)
        var nextFrame = Date()

        while running {
            if link.isConnected {
                do {
                    try renderAndSend()
                } catch {
                    onLog?("frame dropped: \(error)")
                }
            }

            nextFrame = nextFrame.addingTimeInterval(frameDuration)
            let delay = nextFrame.timeIntervalSinceNow
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            } else {
                // Behind schedule: give up the missed frames rather than
                // sprinting to catch up, which would only queue stale video.
                nextFrame = Date()
            }
        }
    }

    private func renderAndSend() throws {
        lock.lock()
        let currentFocus = focus
        lock.unlock()

        let map = try rateMapIfNeeded(for: currentFocus)
        // Everything is sized against the largest map any gaze can produce, so
        // moving the eye never resizes a target or restarts the encoder.
        let allocation = try allocationSize()
        let codec = try codecIfNeeded(width: allocation.width, height: allocation.height)
        try slotsIfNeeded(width: codec.width, height: codec.height)

        // Blocks only when the pipeline is already full, which is the intended
        // backpressure: without it the loop would render frames faster than the
        // encoder drains them and latency would grow without bound.
        inFlight.wait()

        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % slots.count

        var renderConfiguration = RoundTripConfiguration()
        renderConfiguration.width = configuration.width
        renderConfiguration.height = configuration.height
        renderConfiguration.marchSteps = configuration.marchSteps
        renderConfiguration.gaze = currentFocus
        renderConfiguration.time = Float(frameIndex) * 0.011

        let index = frameIndex
        frameIndex += 1
        let generation = rateMapGeneration
        // Stamped before rendering, so the figure the client computes covers
        // render and encode as well as transport. Stamping after encode would
        // report the network alone and flatter the pipeline.
        let stamp = DispatchTime.now().uptimeNanoseconds
        let renderStart = Date()

        try renderer.renderSceneAsync(
            into: slot.texture, rateMap: map, configuration: renderConfiguration
        ) { [weak self] in
            guard let self else { return }
            let renderMilliseconds = Date().timeIntervalSince(renderStart) * 1000

            self.encodeQueue.async {
                codec.encodeAsync(slot.pixelBuffer) { result in
                    defer { self.inFlight.signal() }
                    switch result {
                    case .failure(let error):
                        self.onLog?("frame \(index) dropped: \(error)")
                    case .success(let unit):
                        // Parameter sets must reach the decoder before the frame
                        // that needs them, on the same ordered connection.
                        if let sets = unit.parameterSets, !sets.isEmpty {
                            self.link.send(.parameterSets(sets))
                        }
                        self.link.send(.frame(
                            FrameHeader(
                                index: index,
                                timestampNanoseconds: stamp,
                                rateMapGeneration: generation,
                                isKeyframe: unit.isKeyframe
                            ),
                            payload: unit.data
                        ))
                        self.record(
                            render: renderMilliseconds,
                            encode: unit.encodeMilliseconds,
                            bytes: unit.data.count
                        )
                    }
                }
            }
        }
    }

    private func record(render: Double, encode: Double, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        framesSent += 1
        renderTimes.append(render)
        encodeTimes.append(encode)
        frameSizes.append(bytes)
        // Running averages, not a log.
        if renderTimes.count > 240 { renderTimes.removeFirst(120) }
        if encodeTimes.count > 240 { encodeTimes.removeFirst(120) }
        if frameSizes.count > 240 { frameSizes.removeFirst(120) }
    }

    private func allocationSize() throws -> MTLSize {
        if let cached = cachedAllocation { return cached }
        let size = try RateMapFactory.safePhysicalSize(
            device: device,
            screenWidth: configuration.width,
            screenHeight: configuration.height,
            profile: configuration.profile
        )
        cachedAllocation = size
        return size
    }

    private func slotsIfNeeded(width: Int, height: Int) throws {
        guard slots.count != max(1, configuration.maxFramesInFlight)
                || slots.first?.texture.width != width
                || slots.first?.texture.height != height
        else { return }

        var built: [Slot] = []
        for _ in 0..<max(1, configuration.maxFramesInFlight) {
            let pixelBuffer = try bridge.makePixelBuffer(width: width, height: height)
            built.append(Slot(pixelBuffer: pixelBuffer, texture: try bridge.makeTexture(for: pixelBuffer)))
        }
        slots = built
        nextSlot = 0
    }

    private func rateMapIfNeeded(for focus: SIMD2<Float>) throws -> any MTLRasterizationRateMap {
        let moved = abs(focus.x - rateMapFocus.x) + abs(focus.y - rateMapFocus.y)
        if let existing = rateMap, moved < configuration.focusRebuildThreshold {
            return existing
        }

        let map = try RateMapFactory.makeRateMap(
            device: device,
            screenWidth: configuration.width,
            screenHeight: configuration.height,
            profile: configuration.profile,
            gaze: focus
        )
        let physical = map.physicalSize(layer: 0)

        rateMap = map
        rateMapFocus = focus
        rateMapGeneration += 1

        // The client cannot invert a map it cannot rebuild, so the parameters
        // travel ahead of the first frame that references them.
        link.send(.rateMap(RateMapDescription(
            generation: rateMapGeneration,
            screenWidth: UInt16(configuration.width),
            screenHeight: UInt16(configuration.height),
            physicalWidth: UInt16(physical.width),
            physicalHeight: UInt16(physical.height),
            foveaRadius: configuration.profile.foveaRadius,
            peripheralQuality: configuration.profile.peripheralQuality,
            gazeX: focus.x,
            gazeY: focus.y
        )))

        return map
    }

    private func codecIfNeeded(width: Int, height: Int) throws -> VideoCodec {
        if let codec, codecSize == (width, height) { return codec }
        // A new rate map can change the physical size, and a compression session
        // is fixed to its dimensions.
        let codec = try VideoCodec(width: width, height: height, bitsPerSecond: configuration.bitsPerSecond)
        self.codec = codec
        self.codecSize = (width, height)
        return codec
    }
}

private extension Float {
    func clamped() -> Float { Swift.min(Swift.max(self, 0), 1) }
}
