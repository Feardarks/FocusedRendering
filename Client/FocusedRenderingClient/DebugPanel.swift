import SwiftUI

/// Everything needed to tell a working session from a broken one, without a
/// debugger attached to a headset.
struct DebugPanel: View {
    @Bindable var session: StreamSession
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var immersiveOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Focused Rendering")
                    .font(.largeTitle.bold())

                status
                hosts
                manual
                statistics
                diagnostics
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { session.start() }
    }

    private var status: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.client.state == .streaming ? .green : .orange)
                .frame(width: 12, height: 12)
            Text(session.client.state.label).font(.headline)
            Spacer()
            Button(immersiveOpen ? "Close screen" : "Open screen") {
                Task {
                    if immersiveOpen {
                        await dismissImmersiveSpace()
                        immersiveOpen = false
                    } else {
                        if case .opened = await openImmersiveSpace(id: "screen") {
                            immersiveOpen = true
                        }
                    }
                }
            }
        }
    }

    private var hosts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hosts on this network").font(.headline)
            if session.client.discovered.isEmpty {
                Text("None found yet. Make sure fr-host is running with --stream.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.client.discovered, id: \.self) { name in
                    Button(name) {
                        session.client.connect(toServiceNamed: name, mediaPort: session.mediaPort)
                    }
                }
            }
        }
    }

    private var manual: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Or connect directly").font(.headline)
            HStack {
                TextField("Mac address, e.g. 192.168.1.20", text: $session.manualHost)
                    .textFieldStyle(.roundedBorder)
                Button("Connect") {
                    session.client.connect(toHost: session.manualHost, port: session.mediaPort)
                }
                .disabled(session.manualHost.isEmpty)
            }
            Text("Media port \(session.mediaPort)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var statistics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stream").font(.headline)
            row("Frames received", "\(session.client.framesReceived)")
            row("Frames decoded", "\(session.client.framesDecoded)")
            row("Frame rate", String(format: "%.1f fps", session.client.framesPerSecond))
            row("Bitrate", String(format: "%.1f Mbps", session.client.megabitsPerSecond))
            row("Rate maps", "\(session.client.rateMapGenerations)")
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostics").font(.headline)
            row("Head tracking", session.headPose.isTracking ? "running" : "stopped")
            row("Focus", String(format: "%.2f, %.2f",
                                session.headPose.focus.x, session.headPose.focus.y))

            if let renderer = session.renderer {
                let host = renderer.hostPhysicalSize
                let local = renderer.localPhysicalSize
                row("Encoded size (host)", "\(host.x)×\(host.y)")
                // These must agree. If they do not, the two GPUs rounded the
                // rate map differently and the image will be subtly misaligned.
                row("Rate map (local)", "\(local.x)×\(local.y)",
                    warn: host != .zero && local != .zero && host != local)
                if let error = renderer.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            if let error = session.decodeError {
                Text("Decode: \(error)").font(.caption).foregroundStyle(.red)
            }
            if let error = session.client.lastError {
                Text("Network: \(error)").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced().foregroundStyle(warn ? .red : .primary)
        }
    }
}
