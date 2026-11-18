import Combine
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

@MainActor
final class RemoteTunnel: ObservableObject {
    enum Status: Equatable {
        case off, connecting, forwarding, retrying(String)
    }

    @Published private(set) var status: Status = .off
    private let host: RemoteHost
    private var work: Task<Void, Never>?
    private var process: Process?

    init(host: RemoteHost) { self.host = host }

    func start() {
        guard work == nil, let forwards = host.forwards, !forwards.isEmpty else { return }
        work = Task {
            var retrySeconds = 2
            while !Task.isCancelled {
                status = .connecting
                let message = await connect(forwards)
                guard !Task.isCancelled else { return }
                if status == .forwarding { retrySeconds = 2 }
                status = .retrying(message)
                try? await Task.sleep(for: .seconds(retrySeconds))
                retrySeconds = min(30, retrySeconds * 2)
            }
        }
    }

    func stop() {
        work?.cancel()
        work = nil
        if let process, process.isRunning { process.terminate() }
        status = .off
    }

    private func connect(_ forwards: [LocalForward]) async -> String {
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

            // The master ignores forwards from SSH config. Add just the loopback mappings
            // selected in ColimaDock through its private control socket.
            var command = ["/usr/bin/ssh", "-F", "/dev/null", "-S", socket, "-O", "forward"]
            for forward in forwards { command += ["-L", forward.sshSpec] }
            let result = await CommandRunner.run(command + ["--", host.alias], timeout: 4)
            guard !Task.isCancelled else { return "" }
            guard result.exitCode == 0, child.isRunning else {
                return readLog(log) ?? result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            status = .forwarding
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
