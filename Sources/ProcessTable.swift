import Darwin
import Foundation

/// This user's processes, read straight from the kernel, and a safe way to stop one.
/// A process is identified by pid and start time together, so a recycled pid is never signalled.
enum ProcessTable {
    static func ownProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return [] }

        // Headroom for processes spawned between the size query and the fetch.
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = processes.count * stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        return Array(processes.prefix(size / stride))
    }

    static func processInfo(pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    /// Start time in microseconds since the epoch.
    static func startTime(of info: kinfo_proc) -> UInt64 {
        let start = info.kp_proc.p_un.__p_starttime
        return UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec)
    }

    static func command(of info: kinfo_proc) -> String {
        withUnsafeBytes(of: info.kp_proc.p_comm) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// 1 once the process that started it has exited and launchd adopted it.
    static func parent(of info: kinfo_proc) -> pid_t { info.kp_eproc.e_ppid }

    /// Exact argv via KERN_PROCARGS2: [argc: Int32][exec path\0][padding \0...][argv[0]\0 ... argv[argc-1]\0]...
    static func arguments(of pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, u_int(argMaxMib.count), &argMax, &argMaxSize, nil, 0) == 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size

        // Skip the executable path and the NUL padding after it.
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }

        var argv: [String] = []
        while argv.count < argc && index < size {
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            argv.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return argv.count == argc ? argv : nil
    }

    /// Sends SIGTERM, escalating to SIGKILL, to the process started at `startTime`.
    /// Nil once it is gone, otherwise why it could not be stopped.
    static func stop(pid: pid_t, startTime: UInt64) async -> String? {
        for (signal, grace) in [(SIGTERM, 5.0), (SIGKILL, 2.0)] {
            guard kill(pid, signal) == 0 else {
                return errno == ESRCH ? nil : String(cString: strerror(errno))
            }
            if await waitForExit(pid: pid, startTime: startTime, timeout: grace) {
                return nil
            }
        }
        return "still running after SIGKILL"
    }

    private static func waitForExit(pid: pid_t, startTime: UInt64, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let info = processInfo(pid: pid), self.startTime(of: info) == startTime else {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
