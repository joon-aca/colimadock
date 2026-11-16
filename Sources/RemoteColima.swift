import Combine
import Foundation

struct RemoteHost: Codable, Equatable {
    let name: String
    let alias: String
    let profile: String

    init?(name: String, alias: String, profile: String) {
        func valid(_ token: String, allowed: String, limit: Int) -> Bool {
            let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return (1...limit).contains(token.utf8.count)
                && token.unicodeScalars.first.map(letters.contains) == true
                && token.unicodeScalars.allSatisfy(letters.union(CharacterSet(charactersIn: allowed)).contains)
        }
        guard !name.isEmpty, name.count <= 48, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              valid(alias, allowed: ".-_", limit: 253), valid(profile, allowed: "-_", limit: 64) else { return nil }
        self.name = name
        self.alias = alias
        self.profile = profile
    }

    func ssh(_ command: [String]) -> [String] {
        let environment = ["/usr/bin/env", "-u", "DOCKER_HOST", "-u", "DOCKER_CONTEXT",
                           "-u", "DOCKER_TLS", "-u", "DOCKER_TLS_VERIFY", "-u", "DOCKER_CERT_PATH",
                           "PATH=\(CommandRunner.path)"]
        let remoteCommand = (environment + command).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        // Direct/private-network SSH only. Interactive proxy logins must stay in Terminal.
        return ["/usr/bin/ssh", "-nT", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "-o", "ForwardAgent=no",
                "-o", "ClearAllForwardings=yes", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "--", alias, remoteCommand]
    }

    static func dockerSocket(from statusOutput: String) -> String? {
        for line in statusOutput.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let socket = status["docker_socket"] as? String,
                  socket.hasPrefix("unix:///"), socket.hasSuffix("/docker.sock"),
                  !socket.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            return socket
        }
        return nil
    }
}

@MainActor
final class RemoteColima: ObservableObject {
    enum State: Equatable {
        case checking, unreachable, colimaUnavailable, profileUnavailable, dockerUnavailable, ready

        var label: String {
            switch self {
            case .checking: return "Checking SSH…"
            case .unreachable: return "SSH unavailable"
            case .colimaUnavailable: return "Colima unavailable"
            case .profileUnavailable: return "Profile unavailable"
            case .dockerUnavailable: return "Docker unavailable"
            case .ready: return "Online"
            }
        }
    }

    typealias Runner = @Sendable ([String], TimeInterval) async -> CommandResult
    let host: RemoteHost
    @Published private(set) var state = State.checking
    @Published private(set) var vm: ColimaVM?
    @Published private(set) var containers: [Container] = []
    @Published private(set) var error: String?
    @Published private(set) var operationError: String?
    @Published private(set) var lastOnline: Date?
    @Published private(set) var statsAt: Date?
    @Published private(set) var isActing = false

    private let runner: Runner
    private var dockerSocket: String?
    private var timer: Timer?
    private var isRefreshing = false
    private var refreshPending = false
    private var actionVersion = 0
    private var nextRefresh = Date.distantPast
    private var failures = 0

    var titleStatus: String {
        if state == .profileUnavailable, let vm { return vm.status.displayName }
        return state.label
    }

    init(host: RemoteHost, runner: @escaping Runner = { await CommandRunner.run($0, timeout: $1) }) {
        self.host = host
        self.runner = runner
    }

    func startRefreshing() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Date() >= self.nextRefresh, !self.isRefreshing, !self.isActing else { return }
                self.refresh()
            }
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    func refresh() {
        guard !isRefreshing, !isActing else { refreshPending = true; return }
        isRefreshing = true
        Task {
            let version = actionVersion
            await readSnapshot(version: version)
            isRefreshing = false
            if refreshPending, !isActing {
                refreshPending = false
                refresh()
            }
        }
    }

    func changeContainer(id: String, start: Bool) {
        guard state == .ready, !isActing, let socket = dockerSocket,
              let container = containers.first(where: { $0.id == id }),
              start ? container.state.canStart : container.state.canStop else { return }
        beginAction()
        Task {
            let result = await docker([start ? "start" : "stop", id], socket: socket, timeout: 25)
            if result.exitCode != 0 {
                operationError = "\(start ? "Start" : "Stop") not confirmed: \(detail(result))"
            }
            finishAction(refreshAfter: true)
        }
    }

    func sampleStats() {
        let ids = containers.filter { $0.state.isRunning }.map(\.id)
        guard state == .ready, !isActing, !ids.isEmpty, let socket = dockerSocket else { return }
        beginAction()
        Task {
            let result = await docker(["stats", "--no-stream", "--format", "{{json .}}"] + ids, socket: socket)
            if result.exitCode == 0 {
                let stats = ColimaRuntime.parseStats(result.output)
                applyStats(stats, to: &containers)
                statsAt = Date()
            } else {
                operationError = "Stats unavailable: \(detail(result))"
            }
            finishAction(refreshAfter: false)
        }
    }

    private func beginAction() {
        actionVersion += 1
        isActing = true
        operationError = nil
    }

    private func finishAction(refreshAfter: Bool) {
        isActing = false
        if refreshAfter || refreshPending {
            refreshPending = false
            refresh()
        }
    }

    private func readSnapshot(version: Int) async {
        let list = await run(["colima", "list", "--json"])
        guard version == actionVersion else { refreshPending = true; return }
        guard list.exitCode == 0 else { return failed(.colimaUnavailable, list, vm: nil) }

        let profile = ColimaRuntime.parseVM(list.output, profile: host.profile)
        guard profile.status.isRunning else { return failed(.profileUnavailable, nil, vm: profile) }

        let status = await run(["colima", "status", "--profile", host.profile, "--json"])
        guard version == actionVersion else { refreshPending = true; return }
        guard status.exitCode == 0 else { return failed(.dockerUnavailable, status, vm: profile) }
        guard let socket = RemoteHost.dockerSocket(from: status.output) else {
            return failed(.dockerUnavailable, CommandResult(output: "Profile did not report a Docker Unix socket", exitCode: 1), vm: profile)
        }

        let listContainers = await docker(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], socket: socket)
        guard version == actionVersion else { refreshPending = true; return }
        guard listContainers.exitCode == 0 else { return failed(.dockerUnavailable, listContainers, vm: profile) }
        var updated = ColimaRuntime.parseContainers(listContainers.output).sorted {
            if $0.state.isRunning != $1.state.isRunning { return $0.state.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        applyStats(Dictionary(uniqueKeysWithValues: containers.compactMap { container in
            container.stats.map { (container.id, $0) }
        }), to: &updated)
        vm = profile
        dockerSocket = socket
        containers = updated
        lastOnline = Date()
        error = nil
        state = .ready
        failures = 0
        nextRefresh = Date().addingTimeInterval(20)
    }

    private func failed(_ failure: State, _ result: CommandResult?, vm: ColimaVM?) {
        let unreachable = result.map { $0.exitCode == 255 || $0.timedOut } ?? false
        state = unreachable ? .unreachable : failure
        self.vm = unreachable ? nil : vm
        containers = []
        dockerSocket = nil
        statsAt = nil
        error = result.map(detail)
        failures = min(failures + 1, 3)
        nextRefresh = Date().addingTimeInterval(failure == .profileUnavailable ? 20 : [30, 60, 120][failures - 1])
    }

    private func applyStats(_ stats: [String: ContainerStats], to containers: inout [Container]) {
        for index in containers.indices where containers[index].state.isRunning {
            let container = containers[index]
            containers[index].stats = stats[container.id] ?? stats[container.shortID] ?? stats[container.name]
        }
    }

    private func detail(_ result: CommandResult) -> String {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "Exit code \(result.exitCode)" : output
    }

    private func run(_ command: [String], timeout: TimeInterval = 10) async -> CommandResult {
        await runner(host.ssh(command), timeout)
    }

    private func docker(_ command: [String], socket: String, timeout: TimeInterval = 10) async -> CommandResult {
        await run(["docker", "--host", socket] + command, timeout: timeout)
    }
}
