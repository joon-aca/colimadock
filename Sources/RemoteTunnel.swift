import Combine
import Darwin
import Foundation

struct LocalForward: Codable, Equatable {
    let localPort: UInt16
    let remotePort: UInt16

    var label: String { "\(localPort):\(remotePort)" }
    var sshSpec: String { "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)" }

    static func parse(_ text: String) -> [Self]? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var forwards = [Self]()
        var localPorts = Set<UInt16>()
        for entry in text.split(separator: ",", omittingEmptySubsequences: false) {
            let ports = entry.split(separator: ":", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard ports.count == 2, let local = UInt16(ports[0]), let remote = UInt16(ports[1]),
                  local >= 1024, remote > 0, localPorts.insert(local).inserted else { return nil }
            forwards.append(Self(localPort: local, remotePort: remote))
        }
        return forwards
    }
}

/// Host ports a container publishes over TCP, read from the Ports column of `docker ps`:
/// `0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp, 127.0.0.1:8000-8001->8000-8001/tcp`.
/// Unpublished (`6379/tcp`) and UDP ports are skipped.
enum PublishedPorts {
    /// A range wider than this is skipped rather than opening hundreds of listeners on this Mac.
    static let maxRange = 100

    static func tcp(_ column: String) -> [UInt16] {
        var ports = Set<UInt16>()
        for entry in column.split(separator: ",") {
            let mapping = entry.trimmingCharacters(in: .whitespaces)
            guard mapping.hasSuffix("/tcp"), let arrow = mapping.range(of: "->"),
                  let colon = mapping[..<arrow.lowerBound].lastIndex(of: ":") else { continue }
            let bounds = mapping[mapping.index(after: colon)..<arrow.lowerBound].split(separator: "-").map { UInt16($0) }
            guard let first = bounds.first ?? nil, bounds.count <= 2 else { continue }
            let last = bounds.count == 2 ? bounds[1] : first
            guard let last, first > 0, first <= last, Int(last) - Int(first) < maxRange else { continue }
            ports.formUnion(first...last)
        }
        return ports.sorted()
    }
}

@MainActor
final class RemoteTunnel: ObservableObject {
    enum Status: Equatable {
        case off, connecting, forwarding, retrying(String)
    }

    @Published private(set) var status: Status = .off
    /// Forwards listening on this Mac's localhost right now.
    @Published private(set) var active: [LocalForward] = []
    /// Wanted forwards that could not listen, by local port, with the reason.
    @Published private(set) var blocked: [UInt16: String] = [:]
    /// Ports running containers publish on the remote host, by port, with the container's name.
    @Published private(set) var published: [UInt16: String] = [:]

    private let host: RemoteHost
    private var enabled = false
    private var work: Task<Void, Never>?
    private var process: Process?
    private var controlSocket: String?
    private var reconciling = false
    private var reconcilePending = false

    init(host: RemoteHost) { self.host = host }

    /// The connection's configured forwards, plus each published port on the same
    /// localhost port, the way a local Colima VM forwards them. A configured local port wins.
    static func plan(configured: [LocalForward], published: [UInt16: String]) -> [LocalForward] {
        let taken = Set(configured.map(\.localPort))
        return configured + published.keys.sorted().filter { !taken.contains($0) }
            .map { LocalForward(localPort: $0, remotePort: $0) }
    }

    var wanted: [LocalForward] { Self.plan(configured: host.forwards ?? [], published: published) }

    func start() {
        enabled = true
        sync()
    }

    func stop() {
        enabled = false
        published = [:]
        sync()
    }

    /// Called after every refresh of the remote host with the ports its running containers publish.
    func publish(_ ports: [UInt16: String]) {
        guard enabled else { return }
        if ports != published { published = ports }
        sync()
    }

    /// Keeps one SSH connection open while there is anything to forward, and its
    /// forwards in line with `wanted`. Blocked ports are retried on every call.
    private func sync() {
        if enabled, !wanted.isEmpty {
            if work == nil { connectLoop() } else { Task { await reconcile() } }
        } else if work != nil {
            work?.cancel()
            work = nil
            if let process, process.isRunning { process.terminate() }
            status = .off
            active = []
            blocked = [:]
        }
    }

    private func connectLoop() {
        work = Task {
            var retrySeconds = 2
            while !Task.isCancelled {
                status = .connecting
                let message = await connect()
                guard !Task.isCancelled else { return }
                if status == .forwarding { retrySeconds = 2 }
                status = .retrying(message)
                try? await Task.sleep(for: .seconds(retrySeconds))
                retrySeconds = min(30, retrySeconds * 2)
            }
        }
    }

    /// Adds and cancels forwards on the open connection until they match `wanted`.
    private func reconcile() async {
        guard !reconciling else { reconcilePending = true; return }
        reconciling = true
        defer { reconciling = false }
        repeat {
            reconcilePending = false
            guard let socket = controlSocket else { return }
            let wanted = self.wanted
            for forward in active where !wanted.contains(forward) {
                guard await mux(socket, "cancel", forward) == nil, controlSocket == socket else { return }
                active.removeAll { $0 == forward }
            }
            var stillBlocked = [UInt16: String]()
            for forward in wanted where !active.contains(forward) {
                if let failure = await mux(socket, "forward", forward) {
                    stillBlocked[forward.localPort] = failure
                } else {
                    active.append(forward)
                }
                guard controlSocket == socket else { return }
            }
            active.sort { $0.localPort < $1.localPort }
            if stillBlocked != blocked { blocked = stillBlocked }
        } while reconcilePending
    }

    /// Runs `ssh -O <operation>` for one forward. Nil on success, otherwise why it failed.
    private func mux(_ socket: String, _ operation: String, _ forward: LocalForward) async -> String? {
        let result = await CommandRunner.run(["/usr/bin/ssh", "-F", "/dev/null", "-S", socket, "-O", operation,
                                              "-L", forward.sshSpec, "--", host.alias], timeout: 4)
        guard result.exitCode != 0 else { return nil }
        // SSH reports every refused listener as "Port forwarding failed"; name the usual cause.
        if operation == "forward", Self.localPortInUse(forward.localPort) { return "in use on this Mac" }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "SSH exit code \(result.exitCode)" : output
    }

    /// Whether something on this Mac already listens on 127.0.0.1:`port` (or on all addresses).
    nonisolated static func localPortInUse(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return bound != 0 && errno == EADDRINUSE
    }

    private func connect() async -> String {
        // Keep the path short enough for OpenSSH's temporary Unix socket name.
        let directory = URL(fileURLWithPath: "/tmp/ColimaDock-\(UUID().uuidString)", isDirectory: true)
        let socket = directory.appendingPathComponent("ctl").path
        let log = directory.appendingPathComponent("ssh.log")
        let files = FileManager.default
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
        } catch {
            return error.localizedDescription
        }
        defer { try? files.removeItem(at: directory) }

        do {
            guard files.createFile(atPath: log.path, contents: nil) else { return "Could not capture SSH errors" }
            let writer = try FileHandle(forWritingTo: log)
            defer { try? writer.close() }
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            child.arguments = Array(RemoteHost.sshOptions.dropFirst()) + [
                "-N", "-M", "-S", socket, "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no",
                "-o", "PermitLocalCommand=no", "-o", "LogLevel=ERROR", "--", host.alias
            ]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = FileHandle.nullDevice
            child.standardError = writer
            let exit = AsyncStream<Void> { continuation in
                child.terminationHandler = { _ in continuation.finish() }
            }
            try child.run()
            process = child
            defer {
                if child.isRunning { child.terminate() }
                if process === child { process = nil }
            }

            let deadline = ContinuousClock.now + .seconds(10)
            while child.isRunning, !Task.isCancelled, !files.fileExists(atPath: socket), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return "" }
            guard child.isRunning, files.fileExists(atPath: socket) else {
                return readLog(log) ?? "SSH connection did not become ready"
            }

            // The master ignores forwards from SSH config. ColimaDock adds just its own
            // loopback mappings through the private control socket, and changes them as
            // containers come and go.
            controlSocket = socket
            defer {
                controlSocket = nil
                active = []
                blocked = [:]
            }
            status = .forwarding
            await reconcile()
            for await _ in exit {}
            return readLog(log) ?? "SSH disconnected"
        } catch {
            return error.localizedDescription
        }
    }

    private func readLog(_ url: URL) -> String? {
        guard let reader = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? reader.close() }
        guard let data = try? reader.read(upToCount: 4096) else { return nil }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }
}
