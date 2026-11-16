import Darwin
import Foundation

struct CommandResult: Sendable {
    let output: String
    let exitCode: Int32
    var timedOut = false
}

enum CommandRunner {
    static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func run(
        _ arguments: [String], timeout: TimeInterval,
        environmentOverrides: [String: String] = [:]
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: execute(arguments, timeout: timeout, overrides: environmentOverrides))
            }
        }
    }

    private static func execute(_ arguments: [String], timeout: TimeInterval, overrides: [String: String]) -> CommandResult {
        // A file avoids a full pipe blocking the child or an inherited pipe handle preventing EOF.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("output")
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                return CommandResult(output: "Could not capture command output", exitCode: 1)
            }
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = writer
            process.standardError = writer
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            for key in ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH"] {
                environment.removeValue(forKey: key)
            }
            environment.merge(overrides) { _, override in override }
            process.environment = environment

            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                if process.isRunning { process.terminate() }
                if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                return CommandResult(output: "No response within \(Int(timeout)) seconds", exitCode: 124, timedOut: true)
            }

            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            let limit = 4 * 1024 * 1024
            let data = try reader.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                return CommandResult(output: "Command output exceeded 4 MiB", exitCode: 1)
            }
            return CommandResult(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
        } catch {
            return CommandResult(output: error.localizedDescription, exitCode: 1)
        }
    }
}
