import Combine
import Foundation

struct RemoteHost: Codable, Equatable {
    static let defaultsKey = "remoteColimaHosts.v1"
    let name: String
    let alias: String
    let profile: String
    // Optional so existing saved connections still decode.
    let forwards: [LocalForward]?

    init?(name: String, alias: String, profile: String, forwards: [LocalForward] = []) {
        func valid(_ token: String, allowed: String, limit: Int) -> Bool {
            let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return (1...limit).contains(token.utf8.count)
                && token.unicodeScalars.first.map(letters.contains) == true
                && token.unicodeScalars.allSatisfy(letters.union(CharacterSet(charactersIn: allowed)).contains)
        }
        // An SSH alias or hostname, optionally with the account to log in as: `worker@sparky-local`.
        let target = alias.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let user = target.count == 2 ? target[0] : nil
        guard !name.isEmpty, name.count <= 48, !name.containsControlCharacters,
              valid(target[target.count - 1], allowed: ".-_", limit: 253), user.map({ valid($0, allowed: ".-_", limit: 32) }) ?? true,
              valid(profile, allowed: "-_", limit: 64),
              forwards.allSatisfy({ $0.localPort >= 1024 && $0.remotePort > 0 }),
              Set(forwards.map(\.localPort)).count == forwards.count else { return nil }
        self.name = name
        self.alias = alias
        self.profile = profile
        self.forwards = forwards.isEmpty ? nil : forwards
    }

    func ssh(_ command: [String]) -> [String] {
        let environment = ["/usr/bin/env"] + CommandRunner.dockerEnvironmentKeys.flatMap { ["-u", $0] }
            + ["PATH=\(CommandRunner.path)"]
        let remoteCommand = (environment + command).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        return Self.sshOptions + ["-o", "ControlMaster=no", "-o", "ControlPath=none", "--", alias, remoteCommand]
    }

    // Direct/private-network SSH only. Interactive proxy logins must stay in Terminal.
    static let sshOptions = ["/usr/bin/ssh", "-nT", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
                "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "-o", "ForwardAgent=no",
                "-o", "ClearAllForwardings=yes", "-o", "ProxyCommand=none", "-o", "ProxyJump=none",
                "-o", "PermitLocalCommand=no", "-o", "ForwardX11=no"]

    static func dockerSocket(from statusOutput: String) -> String? {
        for line in statusOutput.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let socket = status["docker_socket"] as? String,
                  socket.hasPrefix("unix:///"), socket.hasSuffix("/docker.sock"),
                  !socket.containsControlCharacters else { continue }
            return socket
        }
        return nil
    }
}

extension String {
    /// Whether any scalar is a control or format character (Unicode Cc/Cf, the
    /// set `CharacterSet.controlCharacters` describes). Checked by category:
    /// `contains(where: CharacterSet.controlCharacters.contains)` returned true
    /// for plain ASCII in this module's release build, rejecting every host.
    var containsControlCharacters: Bool {
        unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) }
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

        /// SSH, Colima or Docker did not answer, as opposed to a VM that is simply stopped.
        var isFailure: Bool { [.unreachable, .colimaUnavailable, .dockerUnavailable].contains(self) }
    }

    typealias Runner = @Sendable ([String], TimeInterval) async -> CommandResult
    let host: RemoteHost
    let tunnel: RemoteTunnel
    @Published private(set) var state = State.checking
    @Published private(set) var vm: ColimaVM?
    @Published private(set) var containers: [Container] = []
    @Published private(set) var error: String?
    @Published private(set) var operationError: String?
    @Published private(set) var lastOnline: Date?
    @Published private(set) var statsAt: Date?
    @Published private(set) var statsError: String?
    @Published private(set) var isActing = false

    private let runner: Runner
    private var dockerSocket: String?
    private var timer: Timer?
    private var isRefreshing = false
    private var refreshPending = false
    private var actionVersion = 0
    private var nextRefresh = Date.distantPast
    private var failures = 0
    /// When the last check began, so opening the menu can tell whether it is current.
    private var checkedAt = Date.distantPast
    /// The next check also samples CPU and memory of the running containers.
    private var statsWanted = false
    /// Opening the menu re-checks a remote whose last check began longer ago than this.
    static let menuFreshness: TimeInterval = 10

    var titleStatus: String {
        if state == .profileUnavailable, let vm { return vm.status.displayName }
        return state.label
    }

    init(host: RemoteHost, runner: @escaping Runner = { await CommandRunner.run($0, timeout: $1) }) {
        self.host = host
        self.runner = runner
        self.tunnel = RemoteTunnel(host: host)
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

    /// Re-checks now, ignoring the schedule and any failure backoff. `withStats` also samples
    /// the running containers' CPU and memory, which takes Docker a couple of seconds.
    func refresh(withStats: Bool = false) {
        if withStats { statsWanted = true }
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
            finishAction()
        }
    }

    /// The menu is opening: bring what it shows up to date, stats included, unless the
    /// last check is recent. The open menu can't change, so this shows on the next open.
    func menuWillOpen(now: Date = Date()) {
        guard now.timeIntervalSince(checkedAt) >= Self.menuFreshness else { return }
        refresh(withStats: true)
    }

    private func beginAction() {
        actionVersion += 1
        isActing = true
        operationError = nil
    }

    /// Re-checks right after an action to show its result.
    private func finishAction() {
        isActing = false
        refreshPending = false
        refresh()
    }

    private func readSnapshot(version: Int) async {
        checkedAt = Date()
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
        let running = updated.filter { $0.state.isRunning }.map(\.id)
        if statsWanted, !running.isEmpty {
            let sample = await docker(["stats", "--no-stream", "--format", "{{json .}}"] + running, socket: socket)
            guard version == actionVersion else { refreshPending = true; return }
            statsWanted = false
            if sample.exitCode == 0 {
                applyStats(ColimaRuntime.parseStats(sample.output), to: &updated)
                statsAt = Date()
                statsError = nil
            } else {
                statsError = "Stats unavailable: \(detail(sample))"
            }
        } else {
            // Keep the last sample until the next one; its time is shown beside it.
            statsWanted = false
            applyStats(Dictionary(uniqueKeysWithValues: containers.compactMap { container in
                container.stats.map { (container.id, $0) }
            }), to: &updated)
        }
        vm = profile
        dockerSocket = socket
        containers = updated
        tunnel.publish(Self.publishedPorts(updated))
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
        tunnel.publish([:])
        dockerSocket = nil
        statsAt = nil
        statsError = nil
        // Asked for while unreachable; the next menu open asks again.
        statsWanted = false
        error = result.map(detail)
        failures = min(failures + 1, 3)
        nextRefresh = Date().addingTimeInterval(failure == .profileUnavailable ? 20 : [30, 60, 120][failures - 1])
    }

    /// Ports published by running containers, by port, with the container's name.
    static func publishedPorts(_ containers: [Container]) -> [UInt16: String] {
        var ports = [UInt16: String]()
        for container in containers where container.state.isRunning {
            for port in PublishedPorts.tcp(container.ports) where ports[port] == nil { ports[port] = container.name }
        }
        return ports
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
