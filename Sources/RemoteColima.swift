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
        case checking, unreachable, colimaUnavailable, profileUnavailable, stopped, dockerUnavailable, ready

        var label: String {
            switch self {
            case .checking: return "Checking SSH…"
            case .unreachable: return "SSH unavailable"
            case .colimaUnavailable: return "Colima unavailable"
            case .profileUnavailable: return "Profile unavailable"
            case .stopped: return "Stopped"
            case .dockerUnavailable: return "Docker unavailable"
            case .ready: return "Online"
            }
        }

        /// SSH, Colima, the profile, or Docker had an error, as opposed to a VM that is simply stopped.
        var isFailure: Bool {
            [.unreachable, .colimaUnavailable, .profileUnavailable, .dockerUnavailable].contains(self)
        }
    }

    enum Activity: Equatable {
        case startingVM
        case stoppingVM
        case restartingVM
        case waitingForDocker
        case container(start: Bool)

        var statusLabel: String? {
            switch self {
            case .startingVM: return "Starting…"
            case .stoppingVM: return "Stopping…"
            case .restartingVM: return "Restarting…"
            case .waitingForDocker: return "Waiting for Docker…"
            case .container: return nil
            }
        }
    }

    struct LifecyclePolicy: Sendable {
        var startTimeout: TimeInterval = 180
        var stopTimeout: TimeInterval = 90
        var readinessAttempts: Int = 6
        var readinessDelay: Duration = .seconds(2)
    }

    private enum Probe {
        case ready(vm: ColimaVM, socket: String, containers: [Container])
        case stopped(vm: ColimaVM)
        case failed(state: State, message: String, vm: ColimaVM?)
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
    @Published private(set) var activity: Activity?

    var isActing: Bool { activity != nil }
    var isTransitioningVM: Bool { activity?.statusLabel != nil }

    var canStartVM: Bool {
        !isActing && state == .stopped && vm?.status == .stopped
    }

    var canStopVM: Bool {
        guard !isActing else { return false }
        switch state {
        case .ready, .dockerUnavailable:
            return true
        case .profileUnavailable:
            return vm.map { $0.status != .missing } ?? false
        case .checking, .unreachable, .colimaUnavailable, .stopped:
            return false
        }
    }

    var canRestartVM: Bool { canStopVM }

    private let runner: Runner
    private let policy: LifecyclePolicy
    private var dockerSocket: String?
    private var timer: Timer?
    private var isRefreshing = false
    private var refreshPending = false
    private var actionVersion = 0
    private var operationGoal: State?
    private var nextRefresh = Date.distantPast
    private var failures = 0
    /// When the last check began, so opening the menu can tell whether it is current.
    private var checkedAt = Date.distantPast
    /// The next check also samples CPU and memory of the running containers.
    private var statsWanted = false
    /// Opening the menu re-checks a remote whose last check began longer ago than this.
    static let menuFreshness: TimeInterval = 10

    var titleStatus: String {
        if let label = activity?.statusLabel { return label }
        if state == .profileUnavailable, let vm {
            return vm.status == .missing ? "Profile not found" : vm.status.displayName
        }
        return state.label
    }

    init(
        host: RemoteHost,
        policy: LifecyclePolicy = .init(),
        runner: @escaping Runner = { await CommandRunner.run($0, timeout: $1) }
    ) {
        self.host = host
        self.policy = policy
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
        refreshPending = false
        isRefreshing = true
        let version = actionVersion
        Task {
            await readSnapshot(version: version)
            isRefreshing = false
            if refreshPending { refresh() }
        }
    }

    func startVM() {
        guard canStartVM else { return }
        let version = beginAction(.startingVM, goal: .ready)
        Task {
            let startResult = await startProfile()
            if startResult.exitCode != 0 {
                await readSnapshot(version: version)
                operationError = "Start \(host.profile) failed: \(failureDetail(startResult))"
                finishAction()
                return
            }
            await waitForDockerReady(actionName: "Start", version: version)
            finishAction()
        }
    }

    func stopVM() {
        guard canStopVM else { return }
        let version = beginAction(.stoppingVM, goal: .stopped)
        Task {
            let stopResult = await run(["colima", "stop", "--profile", host.profile], timeout: policy.stopTimeout)
            checkedAt = Date()
            let outcome = await probe()
            await apply(outcome, version: version)
            if stopResult.exitCode != 0 {
                operationError = "Stop \(host.profile) failed: \(failureDetail(stopResult))"
                operationGoal = .stopped
            } else if case .stopped = outcome {
                operationError = nil
                operationGoal = nil
            } else if case .failed(_, let message, _) = outcome {
                operationError = "Stop \(host.profile) could not be verified: \(message)"
                operationGoal = .stopped
            } else {
                operationError = "Stop \(host.profile) not confirmed: profile is still running"
                operationGoal = .stopped
            }
            finishAction()
        }
    }

    func restartVM() {
        guard canRestartVM else { return }
        let version = beginAction(.restartingVM, goal: .ready)
        Task {
            let stopResult = await run(["colima", "stop", "--profile", host.profile], timeout: policy.stopTimeout)
            if stopResult.exitCode != 0 {
                await readSnapshot(version: version)
                operationError = "Restart \(host.profile) failed while stopping: \(failureDetail(stopResult))"
                finishAction()
                return
            }
            let startResult = await startProfile()
            if startResult.exitCode != 0 {
                await readSnapshot(version: version)
                operationError = "Restart \(host.profile) failed while starting: \(failureDetail(startResult))"
                finishAction()
                return
            }
            await waitForDockerReady(actionName: "Restart", version: version)
            finishAction()
        }
    }

    private func startProfile() async -> CommandResult {
        // Keep the Docker context override temporary for this start.
        await run(
            ["colima", "start", "--profile", host.profile, "--activate=false", "--save-config=false"],
            timeout: policy.startTimeout
        )
    }

    func changeContainer(id: String, start: Bool) {
        guard state == .ready, !isActing, let socket = dockerSocket,
              let container = containers.first(where: { $0.id == id }),
              start ? container.state.canStart : container.state.canStop else { return }
        let version = beginAction(.container(start: start), goal: nil)
        Task {
            let result = await docker([start ? "start" : "stop", id], socket: socket, timeout: 25)
            await readSnapshot(version: version)
            if result.exitCode != 0 {
                operationError = "\(start ? "Start" : "Stop") not confirmed: \(detail(result))"
            }
            finishAction()
        }
    }

    /// The menu is opening: bring what it shows up to date, stats included, unless the
    /// last check is recent and already sampled stats for running containers.
    func menuWillOpen(now: Date = Date()) {
        let needsInitialStats = state == .ready && statsAt == nil && statsError == nil
            && containers.contains(where: { $0.state.isRunning })
        guard now.timeIntervalSince(checkedAt) >= Self.menuFreshness || needsInitialStats else { return }
        refresh(withStats: true)
    }

    private func beginAction(_ nextActivity: Activity, goal: State?) -> Int {
        actionVersion += 1
        activity = nextActivity
        operationError = nil
        operationGoal = goal
        return actionVersion
    }

    private func finishAction() {
        activity = nil
        if refreshPending { refresh() }
    }

    private func waitForDockerReady(actionName: String, version: Int) async {
        activity = .waitingForDocker
        let attempts = max(1, policy.readinessAttempts)

        for attempt in 1...attempts {
            checkedAt = Date()
            let outcome = await probe()
            let problem: String
            var retry = attempt < attempts
            switch outcome {
            case .ready:
                await apply(outcome, version: version)
                return
            case .stopped:
                problem = "profile remained stopped"
            case .failed(let failureState, let message, _):
                problem = message
                retry = retry && failureState != .unreachable
            }
            if retry {
                try? await Task.sleep(for: policy.readinessDelay)
                continue
            }

            await apply(outcome, version: version)
            operationError = "\(actionName) \(host.profile) did not finish: \(problem)"
            return
        }
    }

    private func readSnapshot(version: Int) async {
        checkedAt = Date()
        let outcome = await probe()
        guard version == actionVersion else { refreshPending = true; return }
        await apply(outcome, version: version)
    }

    private func probe() async -> Probe {
        let list = await run(["colima", "list", "--json"])
        if list.exitCode == 255 || list.timedOut {
            return .failed(state: .unreachable, message: failureDetail(list), vm: nil)
        }
        guard list.exitCode == 0 else {
            return .failed(state: .colimaUnavailable, message: detail(list), vm: nil)
        }

        let profile = ColimaRuntime.parseVM(list.output, profile: host.profile)
        if profile.status == .stopped {
            return .stopped(vm: profile)
        }
        if profile.status == .missing {
            return .failed(
                state: .profileUnavailable,
                message: "Colima profile \"\(host.profile)\" was not found on \(host.name)",
                vm: profile
            )
        }
        guard profile.status.isRunning else {
            return .failed(
                state: .profileUnavailable,
                message: "Colima profile \"\(host.profile)\" reported status: \(profile.status.displayName)",
                vm: profile
            )
        }

        let status = await run(["colima", "status", "--profile", host.profile, "--json"])
        if status.exitCode == 255 {
            return .failed(state: .unreachable, message: detail(status), vm: nil)
        }
        if status.timedOut {
            return .failed(
                state: .dockerUnavailable,
                message: "Colima status timed out on \(host.profile): \(detail(status))",
                vm: profile
            )
        }
        guard status.exitCode == 0 else {
            return .failed(state: .dockerUnavailable, message: detail(status), vm: profile)
        }
        guard let socket = RemoteHost.dockerSocket(from: status.output) else {
            return .failed(
                state: .dockerUnavailable,
                message: "Profile \(host.profile) did not report a Docker Unix socket",
                vm: profile
            )
        }

        let listContainers = await docker(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], socket: socket)
        if listContainers.exitCode == 255 {
            return .failed(state: .unreachable, message: detail(listContainers), vm: nil)
        }
        if listContainers.timedOut {
            return .failed(
                state: .dockerUnavailable,
                message: "Docker API timed out on \(host.profile): \(detail(listContainers))",
                vm: profile
            )
        }
        guard listContainers.exitCode == 0 else {
            return .failed(state: .dockerUnavailable, message: detail(listContainers), vm: profile)
        }

        let updated = ColimaRuntime.parseContainers(listContainers.output).sorted {
            if $0.state.isRunning != $1.state.isRunning { return $0.state.isRunning }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return .ready(vm: profile, socket: socket, containers: updated)
    }

    private func apply(_ outcome: Probe, version: Int) async {
        switch outcome {
        case .ready(let profile, let socket, var updated):
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
            tunnel.publish(Self.publishedPorts(updated), forwardingAllowed: true)
            lastOnline = Date()
            error = nil
            state = .ready
            if operationGoal == .ready {
                operationError = nil
                operationGoal = nil
            }
            failures = 0
            nextRefresh = Date().addingTimeInterval(20)

        case .stopped(let profile):
            state = .stopped
            vm = profile
            containers = []
            tunnel.publish([:], forwardingAllowed: false)
            dockerSocket = nil
            statsAt = nil
            statsError = nil
            statsWanted = false
            error = nil
            if operationGoal == .stopped {
                operationError = nil
                operationGoal = nil
            }
            failures = 0
            nextRefresh = Date().addingTimeInterval(20)

        case .failed(let failureState, let message, let profile):
            state = failureState
            vm = profile
            containers = []
            // Drop stale Docker ports. Only change the extra forwards when the VM state is known.
            tunnel.publish([:], forwardingAllowed: profile?.status.isRunning == true ? true : nil)
            dockerSocket = nil
            statsAt = nil
            statsError = nil
            // Asked for while unavailable; the next menu open asks again.
            statsWanted = false
            error = message
            failures = min(failures + 1, 3)
            let delay = failureState == .profileUnavailable ? 20 : [30, 60, 120][failures - 1]
            nextRefresh = Date().addingTimeInterval(TimeInterval(delay))
        }
    }

    private func failureDetail(_ result: CommandResult) -> String {
        if result.exitCode == 255 {
            let text = detail(result)
            return text.hasPrefix("Exit code") ? "SSH connection failed" : text
        }
        return detail(result)
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
