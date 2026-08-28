import Foundation
import FoveatedStreamingHost
import FoveatedStreamingProtocol

// Line-buffer stdout so logs appear immediately when piped to a file or tee.
setvbuf(stdout, nil, _IOLBF, 0)

// Minimal argument parsing keeps the package dependency-free, which matters
// while the toolchain is a beta.
struct Arguments {
    var providerIdentifier = "com.focusedrendering.provider"
    var visionOSBundleID = ""
    var port: UInt16 = 48010
    var serviceName = "Focused Rendering"
    var forceRepair = false
    var qrPath: String?

    static let usage = """
    fr-host — Foveated Streaming session-management endpoint

    USAGE:
      fr-host --bundle-id <visionOS app bundle ID> [options]

    OPTIONS:
      --bundle-id <id>    Bundle ID of the visionOS client (required).
                          Advertised in the Bonjour TXT record; Apple Vision Pro
                          will not connect without a match.
      --provider <id>     Reverse-DNS streaming provider identifier.
                          Default: com.focusedrendering.provider
      --port <n>          TCP port to listen on. Default: 48010
      --name <name>       Bonjour instance name. Default: Focused Rendering
      --force-repair      Ignore remembered pairings and require a QR scan.
      --qr-png <path>     Also write the pairing QR code to this PNG file.
      -h, --help          Show this message.
    """

    static func parse(_ argv: [String]) throws -> Arguments {
        var args = Arguments()
        var index = 0
        while index < argv.count {
            let flag = argv[index]
            func value() throws -> String {
                index += 1
                guard index < argv.count else { throw CLIError.missingValue(flag) }
                return argv[index]
            }
            switch flag {
            case "--bundle-id": args.visionOSBundleID = try value()
            case "--provider": args.providerIdentifier = try value()
            case "--name": args.serviceName = try value()
            case "--qr-png": args.qrPath = try value()
            case "--force-repair": args.forceRepair = true
            case "--port":
                let raw = try value()
                guard let port = UInt16(raw) else { throw CLIError.badValue(flag, raw) }
                args.port = port
            case "-h", "--help": throw CLIError.helpRequested
            default: throw CLIError.unknownFlag(flag)
            }
            index += 1
        }
        guard !args.visionOSBundleID.isEmpty else { throw CLIError.missingValue("--bundle-id") }
        return args
    }
}

enum CLIError: Error, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(String)
    case badValue(String, String)
    case helpRequested

    var description: String {
        switch self {
        case .unknownFlag(let flag): "unknown option \(flag)"
        case .missingValue(let flag): "\(flag) requires a value"
        case .badValue(let flag, let raw): "\(flag) cannot be \"\(raw)\""
        case .helpRequested: ""
        }
    }
}

let arguments: Arguments
do {
    arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch CLIError.helpRequested {
    print(Arguments.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(Arguments.usage)\n".utf8))
    exit(2)
}

// A stable seed keeps client tokens valid across restarts. Tied to the provider
// identifier so two providers on one machine don't share pairing material.
let credentials = DevelopmentCredentials(seed: "focused-rendering::\(arguments.providerIdentifier)")

let configuration = StreamingHostConfiguration(
    port: arguments.port,
    providerIdentifier: arguments.providerIdentifier,
    visionOSBundleID: arguments.visionOSBundleID,
    serviceName: arguments.serviceName,
    forceRepair: arguments.forceRepair
)

let host = StreamingHost(configuration: configuration, credentials: credentials)

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

func log(_ message: String) {
    print("[\(timestamp())] \(message)")
}

let qrPath = arguments.qrPath
host.onEvent = { event in
    switch event {
    case .listening(let port):
        log("listening on port \(port)")
        log("advertising \(ProtocolConstants.serviceType) as \"\(configuration.serviceName)\"")
        log("TXT \(ProtocolConstants.bundleIDKey)=\(configuration.visionOSBundleID)")
        log("provider \(configuration.providerIdentifier)")
    case .clientConnected:
        log("device connected")
    case .clientDisconnected:
        log("device disconnected")
    case .received(let message):
        log("<- \(message)")
    case .sent(let message):
        log("-> \(message.eventName)")
    case .presentBarcode(let payload):
        log("pairing requested — scan this with Apple Vision Pro")
        do {
            let json = try payload.qrPayloadJSON()
            print(try QRCode.ansiArt(json))
            if let qrPath {
                try QRCode.png(json).write(to: URL(fileURLWithPath: qrPath))
                log("QR code also written to \(qrPath)")
            }
        } catch {
            log("could not render QR code: \(error)")
        }
    case .dismissBarcode:
        log("pairing finished — QR code dismissed")
    case .status(let status):
        log("session status \(status.rawValue)")
        if status == .waiting {
            // Nothing connects to the media stream until this is sent. With no
            // stream yet, sending it immediately exercises the rest of the
            // handshake.
            log("signalling MediaStreamIsReady (no media stream yet — M1)")
            host.signalMediaStreamReady()
        }
    case .sessionEnded(let reason):
        log("session ended: \(reason)")
    case .rejected(let reason):
        log("rejected: \(reason)")
    case .failed(let reason):
        log("error: \(reason)")
    }
}

signal(SIGINT, SIG_IGN)
let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupts.setEventHandler {
    log("shutting down")
    host.stop()
    // Give the disconnect request a moment to reach the device.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
}
interrupts.resume()

do {
    try host.start()
} catch {
    FileHandle.standardError.write(Data("error: could not start host: \(error)\n".utf8))
    exit(1)
}

dispatchMain()
