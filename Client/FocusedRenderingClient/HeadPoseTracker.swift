import ARKit
import Foundation
import simd

/// Turns head pose into a focus point on the virtual screen.
///
/// A stand-in for gaze until the foveated streaming entitlement is granted. The
/// eye moves independently of the head — comfortably twenty or thirty degrees
/// either side — so this points at the right place only for large movements.
/// It is enough to exercise the pipeline end to end, not to judge how the
/// foveation looks.
@MainActor
@Observable
final class HeadPoseTracker {

    /// Where the head is pointing on the screen, in 0...1.
    private(set) var focus = SIMD2<Float>(0.5, 0.5)
    private(set) var isTracking = false
    private(set) var lastError: String?

    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var task: Task<Void, Never>?

    /// Geometry of the virtual screen the focus point is measured against.
    /// Must match how `ImmersiveScreen` places it, or the fovea lands off centre.
    struct Screen {
        var distance: Float = 2.0
        var width: Float = 2.6
        var height: Float = 2.28
        var centreHeight: Float = 1.4
    }
    var screen = Screen()

    func start() {
        guard task == nil else { return }
        task = Task {
            do {
                try await session.run([worldTracking])
                isTracking = true
            } catch {
                lastError = "\(error)"
                isTracking = false
                return
            }

            // Polled rather than driven by an update stream: the focus point is
            // only useful as of now, and the render loop upstream is what
            // consumes it.
            while !Task.isCancelled {
                update()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isTracking = false
    }

    private func update() {
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else {
            return
        }
        let transform = anchor.originFromAnchorTransform
        let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        // Devices look down their negative Z axis.
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)

        // The screen sits at a fixed negative Z; a head turned away from it has
        // no intersection to report.
        guard forward.z < -0.05 else { return }
        let t = (-screen.distance - origin.z) / forward.z
        guard t > 0 else { return }

        let hit = origin + forward * t
        let u = (hit.x / screen.width) + 0.5
        let v = 0.5 - ((hit.y - screen.centreHeight) / screen.height)
        focus = SIMD2(min(max(u, 0), 1), min(max(v, 0), 1))
    }
}
