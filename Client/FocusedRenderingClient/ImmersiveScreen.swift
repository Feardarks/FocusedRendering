import RealityKit
import SwiftUI

/// The streamed picture, on a flat panel in front of the wearer.
///
/// Geometry here has to match `HeadPoseTracker.Screen`, since that is what
/// converts where the head points into a focus coordinate.
struct ImmersiveScreen: View {
    private static let screenName = "streamed-screen"

    let session: StreamSession

    var body: some View {
        RealityView { content in
            let screen = session.headPose.screen
            let entity = ModelEntity(
                mesh: .generatePlane(width: screen.width, height: screen.height),
                materials: [UnlitMaterial(color: .gray)]
            )
            entity.name = Self.screenName
            entity.position = [0, screen.centreHeight, -screen.distance]
            content.add(entity)
        } update: { content in
            // The texture does not exist until the first frame has arrived, so
            // the material is attached whenever one shows up. `FrameRenderer` is
            // observable, which is what makes this run at that moment rather
            // than never.
            guard let texture = session.renderer?.textureResource,
                  let entity = content.entities.first(where: { $0.name == Self.screenName }) as? ModelEntity
            else { return }

            var material = UnlitMaterial(color: .white)
            material.color = .init(texture: .init(texture))
            entity.model?.materials = [material]
        }
    }
}
