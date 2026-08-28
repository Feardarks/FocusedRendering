import CoreVideo
import Foundation
import FoveatedPipeline
import FoveatedStreamingHost
import FoveatedStreamingProtocol
import FoveationBenchmark
import Metal

public struct ScreenStreamerConfiguration: Sendable {
    public var framesPerSecond = 90
    /// `off` streams the capture untouched. Anything else trades peripheral
    /// resolution for encoder headroom, which is what buys the frame rate at
    /// higher capture sizes.
    public var profile = FoveationProfile.off
    public var bitsPerSecond = 60_000_000
    public var focusRebuildThreshold: Float = 0.04
    public var maxFramesInFlight = 3
    public var showsCursor = true
    public var captureWidth: Int?
    public var captureHeight: Int?

    public init() {}
}

public struct ScreenStreamerStatistics: Sendable {
    public var framesCaptured = 0
    public var framesSent = 0
    public var framesDropped = 0
    public var meanWarpMilliseconds = 0.0
    public var meanEncodeMilliseconds = 0.0
    public var meanBytesPerFrame = 0
    public var captureSize = SIMD2<Int>.zero
    public var encodeSize = SIMD2<Int>.zero
}

/// Streams a Mac display to the headset.
///
/// Same encode and transport path as the scene streamer; only the source of
/// frames differs. Foveation is applied as a resampling pass here rather than a
/// rasterization rate map, because the image already exists by the time it
/// arrives.
public final class ScreenStreamer: @unchecked Sendable {

    private let configuration: ScreenStreamerConfiguration
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let warpPipeline: any MTLRenderPipelineState
    private let bridge: PixelBufferBridge
    private let link: MediaLink
    private let source: ScreenSource

    private let lock = NSLock()
    private var focus = SIMD2<Float>(0.5, 0.5)

    private struct Slot: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let texture: any MTLTexture
    }
    private var slots: [Slot] = []
    private var nextSlot = 0
    private let inFlight: DispatchSemaphore
    private let encodeQueue = DispatchQueue(label: "com.focusedrendering.screen.encode")

    private var textureCache: CVMetalTextureCache?
    private var rateMap: (any MTLRasterizationRateMap)?
    private var rateMapFocus = SIMD2<Float>(-1, -1)
    private var rateMapGeneration: UInt32 = 0
    private var codec: VideoCodec?
    private var codecSize = (width: 0, height: 0)

    private var frameIndex: UInt64 = 0
    private var statistics = ScreenStreamerStatistics()
    private var warpTimes: [Double] = []
    private var encodeTimes: [Double] = []
    private var frameSizes: [Int] = []

    public var onLog: (@Sendable (String) -> Void)?

    public init(configuration: ScreenStreamerConfiguration, link: MediaLink) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { throw BenchmarkError.noDevice }

        self.configuration = configuration
        self.device = device
        self.queue = queue
        self.warpPipeline = try WarpShader.makePipeline(device: device)
        self.bridge = try PixelBufferBridge(device: device)
        self.link = link
        self.inFlight = DispatchSemaphore(value: max(1, configuration.maxFramesInFlight))

        var captureConfiguration = ScreenSource.Configuration()
        captureConfiguration.framesPerSecond = configuration.framesPerSecond
        captureConfiguration.showsCursor = configuration.showsCursor
        captureConfiguration.width = configuration.captureWidth
        captureConfiguration.height = configuration.captureHeight
        self.source = ScreenSource(configuration: captureConfiguration)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache

        source.onLog = { [weak self] message in self?.onLog?(message) }
        source.onFrame = { [weak self] frame in self?.handle(frame) }
    }

    public func start() async throws {
        try await source.start()
    }

    public func stop() async {
        await source.stop()
    }

    public func updateFocus(_ update: FocusUpdate) {
        lock.lock()
        focus = SIMD2(min(max(update.x, 0), 1), min(max(update.y, 0), 1))
        lock.unlock()
    }

    public var currentStatistics: ScreenStreamerStatistics {
        lock.lock(); defer { lock.unlock() }
        func mean(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        var snapshot = statistics
        snapshot.meanWarpMilliseconds = mean(warpTimes)
        snapshot.meanEncodeMilliseconds = mean(encodeTimes)
        snapshot.meanBytesPerFrame = frameSizes.isEmpty ? 0 : frameSizes.reduce(0, +) / frameSizes.count
        return snapshot
    }

    // MARK: - Per frame

    private func handle(_ captured: CVPixelBuffer) {
        lock.lock()
        statistics.framesCaptured += 1
        let currentFocus = focus
        lock.unlock()

        guard link.isConnected else { return }

        // Never block the capture queue: a frame that cannot be started now is
        // already stale, and holding the queue would stall the capture itself.
        guard inFlight.wait(timeout: .now()) == .success else {
            lock.lock(); statistics.framesDropped += 1; lock.unlock()
            return
        }

        do {
            try encodeAndSend(captured, focus: currentFocus)
        } catch {
            inFlight.signal()
            onLog?("frame dropped: \(error)")
        }
    }

    private func encodeAndSend(_ captured: CVPixelBuffer, focus currentFocus: SIMD2<Float>) throws {
        let screenWidth = CVPixelBufferGetWidth(captured)
        let screenHeight = CVPixelBufferGetHeight(captured)

        let map = try rateMapIfNeeded(for: currentFocus, width: screenWidth, height: screenHeight)
        let allocation = try RateMapFactory.safePhysicalSize(
            device: device, screenWidth: screenWidth, screenHeight: screenHeight,
            profile: configuration.profile
        )
        let codec = try codecIfNeeded(width: allocation.width, height: allocation.height)
        try slotsIfNeeded(width: codec.width, height: codec.height)

        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % slots.count

        guard let cache = textureCache else { throw BenchmarkError.textureCreationFailed }
        var reference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, captured, nil,
            .bgra8Unorm, screenWidth, screenHeight, 0, &reference
        ) == kCVReturnSuccess,
            let reference,
            let sourceTexture = CVMetalTextureGetTexture(reference)
        else { throw BenchmarkError.textureCreationFailed }

        let stamp = DispatchTime.now().uptimeNanoseconds
        let warpStart = Date()
        let index = frameIndex
        frameIndex += 1
        let generation = rateMapGeneration
        let physical = map.physicalSize(layer: 0)

        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw BenchmarkError.encodingFailed
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = slot.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw BenchmarkError.encodingFailed
        }

        let parameterBuffer = try parameterBuffer(for: map)
        encoder.setRenderPipelineState(warpPipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentBuffer(parameterBuffer, offset: 0, index: 0)
        var uniforms = WarpShader.Uniforms(
            screenSize: SIMD2(Float(screenWidth), Float(screenHeight)),
            physicalSize: SIMD2(Float(slot.texture.width), Float(slot.texture.height))
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WarpShader.Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            let warpMilliseconds = Date().timeIntervalSince(warpStart) * 1000
            self.encodeQueue.async {
                codec.encodeAsync(slot.pixelBuffer) { result in
                    defer { self.inFlight.signal() }
                    switch result {
                    case .failure(let error):
                        self.onLog?("frame \(index) dropped: \(error)")
                    case .success(let unit):
                        if let sets = unit.parameterSets, !sets.isEmpty {
                            self.link.send(.parameterSets(sets))
                        }
                        self.link.send(.frame(
                            FrameHeader(
                                index: index, timestampNanoseconds: stamp,
                                rateMapGeneration: generation, isKeyframe: unit.isKeyframe
                            ),
                            payload: unit.data
                        ))
                        self.record(
                            warp: warpMilliseconds, encode: unit.encodeMilliseconds,
                            bytes: unit.data.count,
                            capture: SIMD2(screenWidth, screenHeight),
                            encodeSize: SIMD2(physical.width, physical.height)
                        )
                    }
                }
            }
        }
        commandBuffer.commit()
    }

    private func record(
        warp: Double, encode: Double, bytes: Int,
        capture: SIMD2<Int>, encodeSize: SIMD2<Int>
    ) {
        lock.lock()
        defer { lock.unlock() }
        statistics.framesSent += 1
        statistics.captureSize = capture
        statistics.encodeSize = encodeSize
        warpTimes.append(warp)
        encodeTimes.append(encode)
        frameSizes.append(bytes)
        if warpTimes.count > 240 { warpTimes.removeFirst(120) }
        if encodeTimes.count > 240 { encodeTimes.removeFirst(120) }
        if frameSizes.count > 240 { frameSizes.removeFirst(120) }
    }

    // MARK: - Resources

    private var cachedParameterBuffer: (any MTLBuffer)?
    private var cachedParameterGeneration: UInt32?

    private func parameterBuffer(for map: any MTLRasterizationRateMap) throws -> any MTLBuffer {
        if let cachedParameterBuffer, cachedParameterGeneration == rateMapGeneration {
            return cachedParameterBuffer
        }
        let requirements = map.parameterDataSizeAndAlign
        guard let buffer = device.makeBuffer(length: requirements.size, options: .storageModeShared) else {
            throw BenchmarkError.textureCreationFailed
        }
        map.copyParameterData(buffer: buffer, offset: 0)
        cachedParameterBuffer = buffer
        cachedParameterGeneration = rateMapGeneration
        return buffer
    }

    private func rateMapIfNeeded(
        for focus: SIMD2<Float>, width: Int, height: Int
    ) throws -> any MTLRasterizationRateMap {
        let moved = abs(focus.x - rateMapFocus.x) + abs(focus.y - rateMapFocus.y)
        if let existing = rateMap, moved < configuration.focusRebuildThreshold { return existing }

        let map = try RateMapFactory.makeRateMap(
            device: device, screenWidth: width, screenHeight: height,
            profile: configuration.profile, gaze: focus
        )
        let physical = map.physicalSize(layer: 0)
        rateMap = map
        rateMapFocus = focus
        rateMapGeneration += 1

        link.send(.rateMap(RateMapDescription(
            generation: rateMapGeneration,
            screenWidth: UInt16(width), screenHeight: UInt16(height),
            physicalWidth: UInt16(physical.width), physicalHeight: UInt16(physical.height),
            foveaRadius: configuration.profile.foveaRadius,
            peripheralQuality: configuration.profile.peripheralQuality,
            gazeX: focus.x, gazeY: focus.y
        )))
        return map
    }

    private func codecIfNeeded(width: Int, height: Int) throws -> VideoCodec {
        if let codec, codecSize == (width, height) { return codec }
        let codec = try VideoCodec(width: width, height: height, bitsPerSecond: configuration.bitsPerSecond)
        self.codec = codec
        self.codecSize = (width, height)
        return codec
    }

    private func slotsIfNeeded(width: Int, height: Int) throws {
        guard slots.count != max(1, configuration.maxFramesInFlight)
                || slots.first?.texture.width != width
                || slots.first?.texture.height != height
        else { return }

        var built: [Slot] = []
        for _ in 0..<max(1, configuration.maxFramesInFlight) {
            let buffer = try bridge.makePixelBuffer(width: width, height: height)
            built.append(Slot(pixelBuffer: buffer, texture: try bridge.makeTexture(for: buffer)))
        }
        slots = built
        nextSlot = 0
    }
}
