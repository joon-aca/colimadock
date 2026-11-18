import Darwin
import Foundation

/// A Lima/Colima background process that is still alive but no longer tracked by its pid file.
/// Lima and Colima only ever manage these processes through their pid files, so once the file is
/// gone (or names someone else) nothing will ever stop them: `colima stop` and `limactl stop`
/// cannot see them, and they keep holding memory, sockets, and sometimes the VM's disk.
struct OrphanedProcess: Identifiable, Equatable {
    enum Kind: Equatable {
        case hostAgent
        case networkHelper
        case daemon

        /// The process as it appears in `ps`, for logs.
        var processName: String {
            switch self {
            case .hostAgent: return "limactl hostagent"
            case .networkHelper: return "limactl usernet"
            case .daemon: return "colima daemon"
            }
        }

        /// What the process is, in plain words, for the menu.
        var title: String {
            switch self {
            case .hostAgent: return "VM host agent"
            case .networkHelper: return "Network helper"
            case .daemon: return "Colima daemon"
            }
        }

        var purpose: String {
            switch self {
            case .hostAgent: return "Runs the Colima VM"
            case .networkHelper: return "Networking for the Colima VM"
            case .daemon: return "Colima's background helper"
            }
        }
    }

    let pid: pid_t
    /// Process start time in microseconds since the epoch; together with `pid` it identifies
    /// this exact process so a recycled pid is never signalled.
    let startTime: UInt64
    let kind: Kind
    /// What the process serves: the Lima instance, the Lima network, or the Colima profile.
    let target: String
    let command: String
    let pidFile: String
    /// The pid recorded in `pidFile`, or nil when the file does not exist.
    let pidFileOwner: pid_t?

    var id: pid_t { pid }

    var displayName: String {
        "\(kind.processName) for \(target) (pid \(pid))"
    }

    var startDate: Date {
        Date(timeIntervalSince1970: TimeInterval(startTime) / 1_000_000)
    }

    var reason: String {
        if let owner = pidFileOwner {
            return "Pid file names pid \(owner)"
        }
        return "Pid file missing"
    }
}

enum OrphanedProcessScanner {
    /// Processes younger than this may not have written their pid file yet.
    static let minimumAge: TimeInterval = 30

    struct Paths: Sendable {
        let colimaHome: String
        let limaHome: String
    }

    static func scan(paths: Paths) -> [OrphanedProcess] {
        ProcessTable.ownProcesses().compactMap { evaluate($0, paths: paths) }
    }

    /// Re-verifies `orphan` against the live process table, then sends SIGTERM, escalating to
    /// SIGKILL. Returns an error message, or nil once the process is gone (or no longer orphaned).
    static func terminate(_ orphan: OrphanedProcess, paths: Paths) async -> String? {
        guard let current = ProcessTable.processInfo(pid: orphan.pid).flatMap({ evaluate($0, paths: paths) }),
              current.startTime == orphan.startTime else {
            return nil
        }

        return await ProcessTable.stop(pid: orphan.pid, startTime: orphan.startTime)
            .map { "Could not stop \(orphan.displayName): \($0)" }
    }

    private static func evaluate(_ info: kinfo_proc, paths: Paths) -> OrphanedProcess? {
        let pid = info.kp_proc.p_pid
        let start = ProcessTable.startTime(of: info)
        let age = Date().timeIntervalSince1970 - TimeInterval(start) / 1_000_000
        guard age >= minimumAge else { return nil }

        let name = ProcessTable.command(of: info)
        guard name == "limactl" || name == "colima",
              let argv = ProcessTable.arguments(of: pid),
              let tracked = trackedPidFile(argv: argv, paths: paths) else {
            return nil
        }

        let owner: pid_t?
        switch readPidFile(tracked.pidFile) {
        case .missing: owner = nil
        case .owner(let recorded) where recorded != pid: owner = recorded
        case .owner, .unreadable: return nil
        }

        return OrphanedProcess(
            pid: pid,
            startTime: start,
            kind: tracked.kind,
            target: tracked.target,
            command: argv.joined(separator: " "),
            pidFile: tracked.pidFile,
            pidFileOwner: owner
        )
    }

    /// The pid file a process is managed through, derived the same way Lima and Colima derive it.
    /// Only files under this Colima's homes qualify, so plain Lima instances are never touched.
    private static func trackedPidFile(argv: [String], paths: Paths) -> (kind: OrphanedProcess.Kind, target: String, pidFile: String)? {
        let executable = argv.first.map { ($0 as NSString).lastPathComponent }
        let arguments = Array(argv.dropFirst())

        switch executable {
        case "limactl":
            let subcommands: [String: OrphanedProcess.Kind] = ["hostagent": .hostAgent, "usernet": .networkHelper]
            guard let kind = arguments.lazy.compactMap({ subcommands[$0] }).first,
                  let pidFile = flagValue(in: arguments, names: ["-p", "--pidfile"]),
                  isInside(pidFile, directory: paths.limaHome) else {
                return nil
            }
            // Lima keeps these at <LIMA_HOME>/<instance>/ha.pid and <LIMA_HOME>/_networks/<network>/usernet_*.pid.
            let target = ((pidFile as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return (kind, target, standardized(pidFile))

        case "colima":
            guard let daemonIndex = arguments.firstIndex(of: "daemon"),
                  arguments.indices.contains(daemonIndex + 1),
                  arguments[daemonIndex + 1] == "start" else {
                return nil
            }
            let positional = arguments.dropFirst(daemonIndex + 2).first { !$0.hasPrefix("-") }
            let profile = positional ?? flagValue(in: arguments, names: ["-p", "--profile"]) ?? "default"
            let pidFile = [paths.colimaHome, profile, "daemon", "daemon.pid"].joined(separator: "/")
            return (.daemon, profile, standardized(pidFile))

        default:
            return nil
        }
    }

    private static func flagValue(in arguments: [String], names: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if names.contains(argument), arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            for name in names where argument.hasPrefix(name + "=") {
                return String(argument.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    private static func isInside(_ path: String, directory: String) -> Bool {
        standardized(path).hasPrefix(standardized(directory) + "/")
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private enum PidFileState {
        case missing
        case owner(pid_t)
        case unreadable
    }

    private static func readPidFile(_ path: String) -> PidFileState {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            // Exists but can't be interpreted: not provably orphaned, so leave the process alone.
            return .unreadable
        }
        return .owner(pid)
    }
}
