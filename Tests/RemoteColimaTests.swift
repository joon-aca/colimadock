import XCTest
@testable import ColimaDock

final class RemoteColimaTests: XCTestCase {
    private actor SSH {
        var results: [CommandResult]
        var commands: [[String]] = []

        init(_ results: [CommandResult]) { self.results = results }

        func run(_ command: [String]) -> CommandResult {
            commands.append(command)
            guard !results.isEmpty else { return CommandResult(output: "unexpected command", exitCode: 1) }
            return results.removeFirst()
        }
    }

    private let profileList = CommandResult(output: """
        {"name":"default","status":"Running"}
        {"name":"komodo-dev","status":"Running","cpus":6,"memory":10737418240}
        """, exitCode: 0)
    private let customSocket = CommandResult(output: """
        {"docker_socket":"unix:///Users/joon/Alternate Home/komodo-dev/docker.sock"}
        """, exitCode: 0)
    private let stoppedContainer = CommandResult(output: """
        {"ID":"0123456789abcdef","Names":"komodo-core","State":"exited","Status":"Exited"}
        """, exitCode: 0)

    @MainActor
    func testReadingAndStartingUseDiscoveredRemoteSocket() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let ssh = SSH([profileList, customSocket, stoppedContainer, .init(output: "0123456789abcdef", exitCode: 0),
                       profileList, customSocket, stoppedContainer])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        remote.refresh()
        try await waitFor { remote.state == .ready }
        XCTAssertEqual(remote.vm?.cpus, 6)
        XCTAssertEqual(remote.containers.map(\.name), ["komodo-core"])

        remote.changeContainer(id: "0123456789abcdef", start: true)
        try await waitFor { !remote.isActing }
        let commands = await ssh.commands
        XCTAssertTrue(commands[1].last?.contains("'--profile' 'komodo-dev'") == true)
        for command in commands[2...3] {
            XCTAssertEqual(command.dropLast().last, "sparky-local")
            XCTAssertTrue(command.last?.contains("'docker' '--host' 'unix:///Users/joon/Alternate Home/komodo-dev/docker.sock'") == true)
        }
        XCTAssertTrue(commands[3].last?.hasSuffix("'start' '0123456789abcdef'") == true)
        XCTAssertNil(remote.operationError)
    }

    @MainActor
    func testLostSSHDisablesActionsAndClearsOnlineInventory() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let ssh = SSH([profileList, customSocket, stoppedContainer, .init(output: "Host key verification failed", exitCode: 255)])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        remote.refresh()
        try await waitFor { remote.state == .ready }
        remote.refresh()
        try await waitFor { remote.state == .unreachable }
        XCTAssertEqual(remote.error, "Host key verification failed")
        XCTAssertNotNil(remote.lastOnline)
        XCTAssertTrue(remote.containers.isEmpty)
        remote.changeContainer(id: "0123456789abcdef", start: true)
        let commands = await ssh.commands
        XCTAssertEqual(commands.count, 4)
    }

    @MainActor
    func testUnexpectedEndpointNeverFallsBackToDefaultDocker() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let ssh = SSH([profileList, .init(output: "{\"docker_socket\":\"tcp://unverified:2375\"}", exitCode: 0)])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        remote.refresh()
        try await waitFor { remote.state == .dockerUnavailable }
        let commands = await ssh.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(remote.containers.isEmpty)
    }

    func testSSHRequiresKnownHostAndRejectsOptionLikeAliases() throws {
        XCTAssertNil(RemoteHost(name: "Sparky", alias: "-F", profile: "komodo-dev"))
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let command = host.ssh(["docker", "--host", "unix:///Users/it's me/docker.sock", "ps"])
        XCTAssertTrue(command.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(command.contains("BatchMode=yes"))
        XCTAssertTrue(command.contains("ClearAllForwardings=yes"))
        XCTAssertTrue(command.contains("ProxyCommand=none"))
        XCTAssertTrue(command.last?.contains("'unix:///Users/it'\\''s me/docker.sock'") == true)
    }

    func testExistingConnectionsLoadWithNoForwardAndPortPairsStayOnLoopback() throws {
        let data = Data(#"{"name":"Sparky","alias":"sparky-local","profile":"komodo-dev"}"#.utf8)
        let existing = try JSONDecoder().decode(RemoteHost.self, from: data)
        XCTAssertNil(existing.forwards)
        let forwards = try XCTUnwrap(LocalForward.parse("29120:19120, 6379:6379"))
        XCTAssertEqual(forwards.map(\.sshSpec), ["127.0.0.1:29120:127.0.0.1:19120", "127.0.0.1:6379:127.0.0.1:6379"])
        XCTAssertNil(LocalForward.parse("29120:19120,29120:6379"))
        XCTAssertNil(LocalForward.parse("29120::19120"))
    }

    @MainActor
    func testDiscoversLocalDockerProfilesAlongsideDefault() {
        let output = """
        {"name":"default","status":"Running","runtime":"docker"}
        {"name":"komodo-dev","status":"Running","runtime":"docker"}
        {"name":"other-docker","status":"Stopped","runtime":"docker"}
        {"name":"kubernetes","status":"Running","runtime":"containerd"}
        """
        XCTAssertEqual(ColimaRuntime.parseOtherDockerProfiles(output), ["komodo-dev", "other-docker"])
    }

    func testRunnerCapturesLargeOutputAndBoundsAnUnresponsiveCommand() async {
        let large = await CommandRunner.run(["/usr/bin/head", "-c", "131072", "/dev/zero"], timeout: 3)
        XCTAssertEqual(large.exitCode, 0)
        XCTAssertEqual(large.output.utf8.count, 131072)

        let stalled = await CommandRunner.run(["/bin/sleep", "10"], timeout: 0.1)
        XCTAssertTrue(stalled.timedOut)
        XCTAssertEqual(stalled.exitCode, 124)
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NSError(domain: "RemoteColimaTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "State did not arrive"])
    }
}
