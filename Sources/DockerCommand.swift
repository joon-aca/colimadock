import Darwin
import Foundation

enum DockerCommand {
    static let usage = """
    Usage: ColimaDock docker [--local | --remote] -- <Docker command> [args…]
           ColimaDock docker [--local | --remote] --target

    Choose a preferred connection in ColimaDock's Docker Commands menu first.
    By default the command uses that host if Docker answers, otherwise it tries
    the same Colima profile on this Mac. --local and --remote skip fallback.
    """

    static func run(_ arguments: [String]) async -> Never {
        var mode = DockerRouter.Mode.automatic
        var showTarget = false
        var args = ArraySlice(arguments)
        while let option = args.popFirst() {
            if option == "--" { break }
            switch option {
            case "--help", "-h": print(usage); exit(0)
            case "--local" where mode == .automatic: mode = .localOnly
            case "--remote" where mode == .automatic: mode = .remoteOnly
            case "--target" where !showTarget: showTarget = true
            default: fail("Unexpected option: \(option)\n\(usage)", code: 64)
            }
        }
        guard showTarget ? args.isEmpty : !args.isEmpty else { fail(usage, code: 64) }

        // This is the same executable and bundle as the menu bar app.
        let defaults = UserDefaults.standard
        guard let preference = DockerPreference.load(from: defaults),
              let data = defaults.data(forKey: RemoteHost.defaultsKey),
              let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data),
              let saved = hosts.first(where: { DockerPreference($0) == preference }),
              let host = RemoteHost(name: saved.name, alias: saved.alias, profile: saved.profile) else {
            fail("Open ColimaDock and choose a preferred host under Docker Commands.", code: 78)
        }

        guard let helper = Bundle.main.resourceURL?.appendingPathComponent("DockerSSH", isDirectory: true),
              FileManager.default.isExecutableFile(atPath: helper.appendingPathComponent("ssh").path) else {
            fail("Run this command from a built ColimaDock.app bundle.", code: 78)
        }
        let router = DockerRouter(runner: { await CommandRunner.run($0, timeout: $1, environmentOverrides: $2) },
                                  sshHelperPath: helper.path)
        let target: DockerRouter.Target
        do {
            target = try await router.resolve(host, mode: mode)
        } catch {
            fail(error.localizedDescription, code: 69)
        }

        if showTarget {
            print(target.label)
            exit(0)
        }
        writeError("ColimaDock: using \(target.label)")
        for key in CommandRunner.dockerEnvironmentKeys { unsetenv(key) }
        for (key, value) in router.environment(for: target) { setenv(key, value, 1) }
        // Replace the launcher so Docker retains the terminal, signals, and exit status.
        let command = ["/usr/bin/env"] + target.command + args
        var argv = command.map { strdup($0) } + [nil]
        execv(command[0], &argv)
        fail(String(cString: strerror(errno)), code: 126)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        writeError(message)
        exit(code)
    }
}
