import CoreVideo
import Foundation
import FoveatedStreamingProtocol
import Observation

/// Ties the pieces together: bytes in, picture out, focus back.
@MainActor
@Observable
final class StreamSession {

    let client: StreamClient
    let headPose = HeadPoseTracker()
    private(set) var renderer: FrameRenderer?

    private let decoder = VideoDecoder()
    private(set) var decodeError: String?

    var mediaPort: UInt16 = 48011
    var manualHost = ""

    /// Focus updates are sent on a timer rather than per frame: the host
    /// rebuilds its rate map only when the point moves past a threshold, so
    /// flooding it at frame rate would spend bandwidth to no effect.
    private var focusTimer: Timer?

    init(providerIdentifier: String = "com.focusedrendering.provider") {
        client = StreamClient(providerIdentifier: providerIdentifier)
        do {
            renderer = try FrameRenderer()
        } catch {
            decodeError = "\(error)"
        }
        wire()
    }

    private func wire() {
        client.onParameterSets = { [weak self] sets in
            guard let self else { return }
            do {
                try self.decoder.setParameterSets(sets)
                self.decodeError = nil
            } catch {
                self.decodeError = "\(error)"
            }
        }
        client.onFrame = { [weak self] _, payload in
            guard let self else { return }
            guard let description = self.client.rateMap else { return }
            do {
                guard let frame = try self.decoder.decode(payload) else { return }
                self.renderer?.render(frame, using: description)
                self.client.noteDecoded()
                self.decodeError = nil
            } catch {
                self.decodeError = "\(error)"
            }
        }
    }

    func start() {
        headPose.start()
        client.startBrowsing()
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.client.sendFocus(x: self.headPose.focus.x, y: self.headPose.focus.y)
            }
        }
    }

    func stop() {
        focusTimer?.invalidate()
        focusTimer = nil
        client.disconnect()
        client.stopBrowsing()
        headPose.stop()
    }
}
