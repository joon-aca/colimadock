import Foundation

enum RuntimeStatus: Equatable {
    case running
    case stopped
    case starting
    case stopping
    case missing
    case unknown(String)

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .stopping: return "Stopping..."
        case .missing: return "Missing"
        case .unknown(let value): return value.isEmpty ? "Unknown" : value
        }
    }

    var isRunning: Bool {
        self == .running
    }

    var canAttemptStart: Bool {
        switch self {
        case .running, .starting, .stopping:
            return false
        case .stopped, .missing, .unknown:
            return true
        }
    }

    var isTransitioning: Bool {
        self == .starting || self == .stopping
    }
}

struct ColimaVM: Equatable {
    let profile: String
    var status: RuntimeStatus
    let arch: String
    let cpus: Int
    let memory: UInt64
    let disk: UInt64

    var memoryFormatted: String {
        guard memory > 0 else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)
    }

    var diskFormatted: String {
        guard disk > 0 else { return "Unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(disk), countStyle: .file)
    }
}

enum ContainerState: Equatable {
    case running
    case exited
    case created
    case paused
    case restarting
    case removing
    case dead
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "running": self = .running
        case "exited": self = .exited
        case "created": self = .created
        case "paused": self = .paused
        case "restarting": self = .restarting
        case "removing": self = .removing
        case "dead": self = .dead
        default: self = .unknown(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .exited: return "Stopped"
        case .created: return "Created"
        case .paused: return "Paused"
        case .restarting: return "Restarting"
        case .removing: return "Removing"
        case .dead: return "Dead"
        case .unknown(let value): return value.isEmpty ? "Unknown" : value
        }
    }

    var isRunning: Bool {
        self == .running
    }

    var canStart: Bool {
        switch self {
        case .exited, .created, .dead:
            return true
        default:
            return false
        }
    }

    var canStop: Bool {
        switch self {
        case .running, .paused, .restarting:
            return true
        default:
            return false
        }
    }
}

struct ContainerStats: Equatable {
    let cpuPercent: String
    let memoryUsage: String
    let memoryPercent: String
    let networkIO: String
    let blockIO: String
    let pids: String
}

struct Container: Identifiable, Equatable {
    let id: String
    let shortID: String
    let name: String
    let image: String
    var state: ContainerState
    let status: String
    let ports: String
    var stats: ContainerStats?
    var isTransitioning: Bool
}

@MainActor
final class ColimaRuntime: ObservableObject {
    @Published private(set) var vm = ColimaVM(
        profile: "default",
        status: .unknown("Loading"),
        arch: "Unknown",
        cpus: 0,
        memory: 0,
        disk: 0
    )
    @Published private(set) var containers: [Container] = []
    @Published private(set) var isLoading = true
    @Published private(set) var lastError: String?

    private let colimaPath: String
    private let dockerPath: String
    private var refreshTimer: Timer?
    private var transitioningContainers = Set<String>()

    var hasRunningContainer: Bool {
        containers.contains { $0.state.isRunning }
    }

    var isTransitioning: Bool {
        vm.status.isTransitioning || containers.contains { $0.isTransitioning }
    }

    init() {
        self.colimaPath = Self.findExecutable("colima")
        self.dockerPath = Self.findExecutable("docker")
        startRefreshing()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func startRefreshing() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTransitioning else { return }
                self.refresh()
            }
        }
    }

    func refresh() {
        Task {
            await refreshSnapshot()
        }
    }

    func startVM() {
        guard vm.status.canAttemptStart else { return }
        vm.status = .starting

        Task {
            let result = await runCommand([colimaPath, "start"])
            if result.exitCode != 0 {
                lastError = cleanError(result.output)
            }
            await refreshSnapshot()
        }
    }

    func stopVM() {
        guard vm.status.isRunning else { return }
        vm.status = .stopping
        containers = containers.map { container in
            var updated = container
            updated.isTransitioning = true
            return updated
        }

        Task {
            let result = await runCommand([colimaPath, "stop"])
            if result.exitCode != 0 {
                lastError = cleanError(result.output)
            }
            transitioningContainers.removeAll()
            await refreshSnapshot()
        }
    }

    func startContainer(id: String) {
        guard let container = containers.first(where: { $0.id == id || $0.shortID == id }),
              container.state.canStart else { return }

        transitioningContainers.insert(container.id)
        updateContainerTransition(id: container.id, isTransitioning: true)

        Task {
            let result = await runCommand([dockerPath, "start", container.id])
            if result.exitCode != 0 {
                lastError = cleanError(result.output)
            }
            transitioningContainers.remove(container.id)
            await refreshSnapshot()
        }
    }

    func stopContainer(id: String) {
        guard let container = containers.first(where: { $0.id == id || $0.shortID == id }),
              container.state.canStop else { return }

        transitioningContainers.insert(container.id)
        updateContainerTransition(id: container.id, isTransitioning: true)

        Task {
            let result = await runCommand([dockerPath, "stop", container.id])
            if result.exitCode != 0 {
                lastError = cleanError(result.output)
            }
            transitioningContainers.remove(container.id)
            await refreshSnapshot()
        }
    }

    private func refreshSnapshot() async {
        let vmResult = await runCommand([colimaPath, "ls", "--json"])
        guard vmResult.exitCode == 0 else {
            vm = ColimaVM(profile: "default", status: .unknown("Colima unavailable"), arch: "Unknown", cpus: 0, memory: 0, disk: 0)
            containers = []
            lastError = cleanError(vmResult.output)
            isLoading = false
            return
        }

        let parsedVM = parseDefaultVM(vmResult.output)
        vm = parsedVM

        guard parsedVM.status.isRunning else {
            containers = []
            lastError = nil
            isLoading = false
            return
        }

        let containersResult = await runCommand([
            dockerPath,
            "ps",
            "-a",
            "--format",
            "{{json .}}"
        ])

        guard containersResult.exitCode == 0 else {
            containers = []
            lastError = cleanError(containersResult.output)
            isLoading = false
            return
        }

        var parsedContainers = parseContainers(containersResult.output)
        let runningIDs = parsedContainers.filter { $0.state.isRunning }.map(\.id)
        let stats = await fetchStats(containerIDs: runningIDs)

        parsedContainers = parsedContainers.map { container in
            var updated = container
            updated.stats = stats[container.id] ?? stats[container.shortID] ?? stats[container.name]
            updated.isTransitioning = transitioningContainers.contains(container.id)
            return updated
        }

        containers = parsedContainers.sorted {
            if $0.state.isRunning != $1.state.isRunning {
                return $0.state.isRunning
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        lastError = nil
        isLoading = false
    }

    private func fetchStats(containerIDs: [String]) async -> [String: ContainerStats] {
        guard !containerIDs.isEmpty else { return [:] }

        let result = await runCommand([
            dockerPath,
            "stats",
            "--no-stream",
            "--format",
            "{{json .}}"
        ] + containerIDs)

        guard result.exitCode == 0 else { return [:] }

        return parseStats(result.output)
    }

    private func parseDefaultVM(_ output: String) -> ColimaVM {
        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            guard let json = decodeJSONObject(line),
                  let name = json["name"] as? String,
                  name == "default" else {
                continue
            }

            return ColimaVM(
                profile: name,
                status: parseRuntimeStatus(json["status"] as? String ?? ""),
                arch: json["arch"] as? String ?? "Unknown",
                cpus: json["cpus"] as? Int ?? 0,
                memory: parseUInt64(json["memory"]),
                disk: parseUInt64(json["disk"])
            )
        }

        return ColimaVM(profile: "default", status: .missing, arch: "Unknown", cpus: 0, memory: 0, disk: 0)
    }

    private func parseContainers(_ output: String) -> [Container] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard !line.isEmpty,
                  let json = decodeJSONObject(line),
                  let id = json["ID"] as? String,
                  let name = json["Names"] as? String else {
                return nil
            }

            return Container(
                id: id,
                shortID: String(id.prefix(12)),
                name: name,
                image: json["Image"] as? String ?? "Unknown",
                state: ContainerState(rawValue: json["State"] as? String ?? ""),
                status: json["Status"] as? String ?? "Unknown",
                ports: json["Ports"] as? String ?? "",
                stats: nil,
                isTransitioning: transitioningContainers.contains(id)
            )
        }
    }

    private func parseStats(_ output: String) -> [String: ContainerStats] {
        var results: [String: ContainerStats] = [:]

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            guard let json = decodeJSONObject(line) else { continue }

            let stats = ContainerStats(
                cpuPercent: json["CPUPerc"] as? String ?? "Unknown",
                memoryUsage: json["MemUsage"] as? String ?? "Unknown",
                memoryPercent: json["MemPerc"] as? String ?? "Unknown",
                networkIO: json["NetIO"] as? String ?? "Unknown",
                blockIO: json["BlockIO"] as? String ?? "Unknown",
                pids: json["PIDs"] as? String ?? "Unknown"
            )

            for key in ["Container", "ID", "Name"] {
                if let value = json[key] as? String, !value.isEmpty {
                    results[value] = stats
                }
            }
        }

        return results
    }

    private func updateContainerTransition(id: String, isTransitioning: Bool) {
        containers = containers.map { container in
            guard container.id == id else { return container }
            var updated = container
            updated.isTransitioning = isTransitioning
            return updated
        }
    }

    private func parseRuntimeStatus(_ value: String) -> RuntimeStatus {
        switch value.lowercased() {
        case "running": return .running
        case "stopped": return .stopped
        default: return .unknown(value)
        }
    }

    private func decodeJSONObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parseUInt64(_ value: Any?) -> UInt64 {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int {
            return UInt64(max(value, 0))
        }
        if let value = value as? Double {
            return UInt64(max(value, 0))
        }
        if let value = value as? String {
            return UInt64(value) ?? 0
        }
        return 0
    }

    private func cleanError(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func findExecutable(_ name: String) -> String {
        let possiblePaths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        for path in possiblePaths where FileManager.default.fileExists(atPath: path) {
            return path
        }

        return name
    }

    private func runCommand(_ arguments: [String]) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe

                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                process.environment = environment

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""

                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: ("Error: \(error.localizedDescription)", 1))
                }
            }
        }
    }
}
