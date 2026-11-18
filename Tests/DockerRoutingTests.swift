import XCTest
@testable import ColimaDock

final class DockerRoutingTests: XCTestCase {
    private struct Call {
        let arguments: [String]
        let environment: [String: String]
    }

    private actor Engine {
        var calls: [Call] = []
        var responses: [CommandResult]

        init(_ responses: [CommandResult]) { self.responses = responses }

        func run(_ args: [String], environment: [String: String]) -> CommandResult {
            calls.append(Call(arguments: args, environment: environment))
            return responses.isEmpty ? CommandResult(output: "Unexpected command", exitCode: 1) : responses.removeFirst()
        }
    }

    private let remoteStatus = CommandResult(output: #"{"docker_socket":"unix:///Remote Home/komodo-dev/docker.sock"}"#, exitCode: 0)
    private let localStatus = CommandResult(output: #"{"docker_socket":"unix:///Local/.colima/komodo-dev/docker.sock"}"#, exitCode: 0)
    private let ready = CommandResult(output: "29.1.5", exitCode: 0)
    private let sshOffline = CommandResult(output: "Could not resolve hostname", exitCode: 255)
    private let dockerOffline = CommandResult(output: "Cannot connect to the Docker daemon", exitCode: 1)

    private func host() throws -> RemoteHost {
        try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
    }

    private func router(_ engine: Engine) -> DockerRouter {
        DockerRouter(runner: { args, _, env in await engine.run(args, environment: env) }, sshHelperPath: "/App/DockerSSH")
    }

    func testPrefersReachableRemoteEngineAndUsesItsExactSocket() async throws {
        let engine = Engine([remoteStatus, ready])
        let target = try await router(engine).resolve(host(), mode: .automatic)
        XCTAssertEqual(target, .init(endpoint: "ssh://sparky-local/Remote%20Home/komodo-dev/docker.sock",
                                     label: "Sparky", isRemote: true))
        let calls = await engine.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.arguments.dropLast().last, "sparky-local")
        XCTAssertTrue(calls.first?.arguments.last?.hasSuffix("'colima' 'status' '--profile' 'komodo-dev' '--json'") == true)
        XCTAssertEqual(calls.last?.arguments, target.command + ["version", "--format", "{{.Server.Version}}"])
        XCTAssertTrue(calls.last?.environment["PATH"]?.hasPrefix("/App/DockerSSH:") == true)
    }

    func testSSHAndDockerFailuresBothFallBackToMatchingLocalProfile() async throws {
        for responses in [[sshOffline], [remoteStatus, dockerOffline]] {
            let engine = Engine(responses + [localStatus, ready])
            let target = try await router(engine).resolve(host(), mode: .automatic)
            XCTAssertEqual(target, .init(endpoint: "unix:///Local/.colima/komodo-dev/docker.sock",
                                         label: "This Mac (komodo-dev)", isRemote: false))
            let calls = await engine.calls
            XCTAssertEqual(calls.count, responses.count + 2)
            XCTAssertEqual(calls[responses.count].arguments, ["colima", "status", "--profile", "komodo-dev", "--json"])
            XCTAssertEqual(calls.last?.arguments, target.command + ["version", "--format", "{{.Server.Version}}"])
            XCTAssertFalse(calls.last?.environment["PATH"]?.contains("DockerSSH") == true)
        }
    }

    func testPinnedModesNeverProbeAnotherHost() async throws {
        let remote = Engine([sshOffline])
        do {
            _ = try await router(remote).resolve(host(), mode: .remoteOnly)
            XCTFail("Remote-only mode should fail if Sparky is unavailable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sparky"))
        }
        let failedRemoteCalls = await remote.calls
        XCTAssertEqual(failedRemoteCalls.count, 1)

        let local = Engine([localStatus, ready])
        let target = try await router(local).resolve(host(), mode: .localOnly)
        XCTAssertFalse(target.isRemote)
        let localCalls = await local.calls
        XCTAssertEqual(localCalls.map { $0.arguments.first }, ["colima", "docker"])
    }

    func testWhenBothEnginesAreUnavailableReportsBothFailures() async throws {
        let stopped = CommandResult(output: "colima is not running", exitCode: 1)
        let engines = Engine([sshOffline, stopped])
        do {
            _ = try await router(engines).resolve(host(), mode: .automatic)
            XCTFail("A stopped local VM should never be selected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Sparky: Could not resolve hostname"))
            XCTAssertTrue(error.localizedDescription.contains("This Mac (komodo-dev): colima is not running"))
        }
        let calls = await engines.calls
        XCTAssertEqual(calls.count, 2)
    }
}
