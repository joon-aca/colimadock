import Foundation

struct DockerPreference: Codable, Equatable {
    static let defaultsKey = "preferredDockerHost.v1"

    let alias: String
    let profile: String

    init(_ host: RemoteHost) {
        alias = host.alias
        profile = host.profile
    }

    static func load(from defaults: UserDefaults) -> Self? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

struct DockerRouter {
    enum Mode { case automatic, remoteOnly, localOnly }

    struct Target: Equatable {
        let endpoint: String
        let label: String
        let isRemote: Bool

        var command: [String] { ["docker", "--host", endpoint] }
    }

    struct Unavailable: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    typealias Runner = ([String], TimeInterval, [String: String]) async -> CommandResult
    let runner: Runner
    let sshHelperPath: String

    func resolve(_ host: RemoteHost, mode: Mode) async throws -> Target {
        let status = ["colima", "status", "--profile", host.profile, "--json"]
        var remoteError: String?
        if mode != .localOnly {
            do {
                let socket = try await discoverSocket(using: host.ssh(status), timeout: 7)
                var url = URLComponents()
                url.scheme = "ssh"
                url.host = host.alias
                url.path = String(socket.dropFirst("unix://".count))
                guard let endpoint = url.string else { throw Unavailable(reason: "Invalid SSH socket URL") }
                let remote = Target(endpoint: endpoint, label: host.name, isRemote: true)
                try await checkDocker(remote)
                return remote
            } catch {
                let message = "\(host.name): \(error.localizedDescription)"
                if mode == .remoteOnly { throw Unavailable(reason: message) }
                remoteError = message
            }
        }

        do {
            let socket = try await discoverSocket(using: status, timeout: 4)
            let local = Target(endpoint: socket, label: "This Mac (\(host.profile))", isRemote: false)
            try await checkDocker(local)
            return local
        } catch {
            let localError = "This Mac (\(host.profile)): \(error.localizedDescription)"
            throw Unavailable(reason: [remoteError, localError].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    func environment(for target: Target) -> [String: String] {
        target.isRemote ? ["PATH": "\(sshHelperPath):\(CommandRunner.path)"] : ["PATH": CommandRunner.path]
    }

    private func discoverSocket(using command: [String], timeout: TimeInterval) async throws -> String {
        let result = await runner(command, timeout, [:])
        guard result.exitCode == 0 else { throw Unavailable(reason: detail(result)) }
        guard let socket = RemoteHost.dockerSocket(from: result.output) else {
            throw Unavailable(reason: "Colima did not report a Docker socket")
        }
        return socket
    }

    private func checkDocker(_ target: Target) async throws {
        let result = await runner(target.command + ["version", "--format", "{{.Server.Version}}"],
                                  target.isRemote ? 7 : 4, environment(for: target))
        guard result.exitCode == 0, !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Unavailable(reason: detail(result))
        }
    }

    private func detail(_ result: CommandResult) -> String {
        let lines = result.output.split(whereSeparator: \.isNewline)
        return lines.last.map(String.init) ?? "Docker did not respond (exit \(result.exitCode))"
    }
}
