import AppKit
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
    func testRefreshRequestedDuringContainerActionRunsAfterVerification() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let stoppedProfile = CommandResult(output: #"{"name":"komodo-dev","status":"Stopped"}"#, exitCode: 0)
        let stats = CommandResult(output: #"{"ID":"0123456789ab","CPUPerc":"3.10%"}"#, exitCode: 0)
        let ssh = SSH([
            profileList, customSocket, stoppedContainer,
            .init(output: "0123456789abcdef", exitCode: 0),
            profileList, customSocket, runningContainer, stats,
            stoppedProfile,
        ])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        remote.refresh()
        try await waitFor { remote.state == .ready }

        remote.changeContainer(id: "0123456789abcdef", start: true)
        XCTAssertTrue(remote.isActing)
        remote.refresh(withStats: true)
        remote.refresh(withStats: true)

        try await waitFor { remote.state == .stopped }
        let commands = await ssh.commands
        XCTAssertEqual(commands.count, 9)
        XCTAssertTrue(commands[7].last?.contains("'stats' '--no-stream'") == true)
        XCTAssertTrue(commands[8].last?.hasSuffix("'colima' 'list' '--json'") == true)
    }

    private let runningContainer = CommandResult(output: """
        {"ID":"0123456789abcdef","Names":"komodo-core","State":"running","Status":"Up 2 hours"}
        """, exitCode: 0)

    @MainActor
    func testOpeningTheMenuChecksAndSamplesStatsUnlessJustChecked() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let stats = CommandResult(output: """
            {"ID":"0123456789ab","CPUPerc":"3.10%","MemUsage":"512MiB / 10GiB","MemPerc":"5.00%"}
            """, exitCode: 0)
        let ssh = SSH([profileList, customSocket, runningContainer, stats])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        remote.menuWillOpen()
        try await waitFor { remote.statsAt != nil }
        XCTAssertEqual(remote.containers.first?.stats?.cpuPercent, "3.10%")
        let commands = await ssh.commands
        XCTAssertTrue(commands[3].last?.contains("'stats' '--no-stream'") == true)

        remote.menuWillOpen()
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterReopen = await ssh.commands
        XCTAssertEqual(afterReopen.count, 4, "a menu reopened right after a check doesn't check again")
    }

    @MainActor
    func testFailedStatsSampleWarnsButKeepsTheRemoteOnline() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let ssh = SSH([profileList, customSocket, runningContainer, .init(output: "stats timed out", exitCode: 1)])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        remote.refresh(withStats: true)
        try await waitFor { remote.statsError != nil }
        XCTAssertEqual(remote.state, .ready)
        XCTAssertEqual(remote.containers.map(\.name), ["komodo-core"])
        XCTAssertEqual(remote.statsError, "Stats unavailable: stats timed out")
        XCTAssertNil(remote.statsAt)
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

    func testPlainNamesAndSocketsPassAndControlCharactersDoNot() throws {
        XCTAssertNotNil(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "offload"))
        XCTAssertNil(RemoteHost(name: "Spar\u{7}ky", alias: "sparky-local", profile: "offload"))
        XCTAssertNil(RemoteHost(name: "Spar\u{200B}ky", alias: "sparky-local", profile: "offload"))
        XCTAssertEqual(RemoteHost.dockerSocket(from: #"{"docker_socket":"unix:///Users/worker/.colima/big/docker.sock"}"#),
                       "unix:///Users/worker/.colima/big/docker.sock")
        XCTAssertNil(RemoteHost.dockerSocket(from: #"{"docker_socket":"unix:///tmp/a\u0007/docker.sock"}"#))
    }

    func testOnlyConnectionProblemsCountAsFailures() {
        let states: [RemoteColima.State] = [
            .checking, .unreachable, .colimaUnavailable, .profileUnavailable, .stopped, .dockerUnavailable, .ready
        ]
        XCTAssertEqual(states.map(\.isFailure), [false, true, true, true, false, true, false])
    }

    @MainActor
    func testStoppedNamedProfileStartsRetriesReadinessAndRestoresForwardsLeavingDefaultAlone() async throws {
        let forwards = try XCTUnwrap(LocalForward.parse("29120:19120"))
        let host = try XCTUnwrap(
            RemoteHost(name: "Sparky", alias: "worker@sparky-local", profile: "komodo-dev", forwards: forwards)
        )
        let komodoStopped = CommandResult(output: """
            {"name":"default","status":"Stopped"}
            {"name":"komodo-dev","status":"Stopped","cpus":6,"memory":10737418240}
            """, exitCode: 0)
        let komodoRunning = CommandResult(output: """
            {"name":"default","status":"Stopped"}
            {"name":"komodo-dev","status":"Running","cpus":6,"memory":10737418240}
            """, exitCode: 0)
        let publishedPostgres = CommandResult(output: """
            {"ID":"a1b2c3d4e5f60000","Names":"postgres","State":"running","Status":"Up 2 seconds","Ports":"0.0.0.0:5432->5432/tcp"}
            """, exitCode: 0)

        let ssh = SSH([
            komodoStopped,
            // colima start succeeds; first Docker probe isn't ready yet, second succeeds.
            .init(output: "done", exitCode: 0),
            komodoRunning, customSocket, .init(output: "Cannot connect to the Docker daemon", exitCode: 1),
            komodoRunning, customSocket, publishedPostgres,
        ])
        let fastPolicy = RemoteColima.LifecyclePolicy(
            startTimeout: 180, stopTimeout: 90, readinessAttempts: 3, readinessDelay: .milliseconds(5)
        )
        let remote = RemoteColima(host: host, policy: fastPolicy, runner: { args, _ in await ssh.run(args) })

        remote.refresh()
        try await waitFor { remote.state == .stopped }
        XCTAssertTrue(remote.canStartVM)
        XCTAssertFalse(remote.canStopVM)
        XCTAssertFalse(remote.canRestartVM)
        XCTAssertTrue(remote.tunnel.wanted.isEmpty, "stopped profile does not hold local forwards")

        remote.startVM()
        try await waitFor { !remote.isActing }
        XCTAssertEqual(remote.state, .ready)
        XCTAssertNil(remote.operationError)
        XCTAssertEqual(remote.containers.map(\.name), ["postgres"])
        XCTAssertEqual(remote.tunnel.wanted.map(\.label), ["29120:19120", "5432:5432"])

        let commands = await ssh.commands
        XCTAssertEqual(commands.count, 8)
        XCTAssertTrue(commands[1].last?.hasSuffix(
            "'colima' 'start' '--profile' 'komodo-dev' '--activate=false' '--save-config=false'"
        ) == true)
        for command in commands where command.last?.contains("'--profile'") == true {
            XCTAssertTrue(command.last?.contains("'--profile' 'komodo-dev'") == true)
            XCTAssertFalse(command.last?.contains("'--profile' 'default'") == true)
        }
    }

    @MainActor
    func testDockerTimeoutStaysDistinctFromSSHAndRestartHandlesFailureThenEmptyContainerSuccess() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let dockerTimedOut = CommandResult(output: "No response within 10 seconds", exitCode: 124, timedOut: true)
        let emptyContainers = CommandResult(output: "", exitCode: 0)

        let ssh = SSH([
            // Initial check: SSH + Colima succeed, Docker probe times out.
            profileList, customSocket, dockerTimedOut,
            // First restart: stop + start succeed, both readiness probes time out on Docker.
            .init(output: "stopped", exitCode: 0),
            .init(output: "started", exitCode: 0),
            profileList, customSocket, dockerTimedOut,
            profileList, customSocket, dockerTimedOut,
            // Second restart: stop + start succeed, Docker answers with an empty container list.
            .init(output: "stopped", exitCode: 0),
            .init(output: "started", exitCode: 0),
            profileList, customSocket, emptyContainers,
        ])
        let fastPolicy = RemoteColima.LifecyclePolicy(
            startTimeout: 180, stopTimeout: 90, readinessAttempts: 2, readinessDelay: .milliseconds(5)
        )
        let remote = RemoteColima(host: host, policy: fastPolicy, runner: { args, _ in await ssh.run(args) })

        remote.refresh()
        try await waitFor { remote.state == .dockerUnavailable }
        XCTAssertEqual(remote.vm?.status, .running)
        XCTAssertEqual(remote.error, "Docker API timed out on komodo-dev: No response within 10 seconds")
        XCTAssertTrue(remote.canRestartVM)
        XCTAssertTrue(remote.canStopVM)
        XCTAssertFalse(remote.canStartVM)

        remote.restartVM()
        try await waitFor { !remote.isActing }
        XCTAssertEqual(remote.state, .dockerUnavailable)
        XCTAssertEqual(
            remote.operationError,
            "Restart komodo-dev did not finish: Docker API timed out on komodo-dev: No response within 10 seconds"
        )
        XCTAssertTrue(remote.canRestartVM)

        remote.restartVM()
        try await waitFor { !remote.isActing }
        XCTAssertEqual(remote.state, .ready)
        XCTAssertTrue(remote.containers.isEmpty)
        XCTAssertNil(remote.operationError, "reaching ready clears the earlier restart error")

        let commands = await ssh.commands
        let startCommands = commands.compactMap(\.last).filter { $0.contains("'colima' 'start'") }
        XCTAssertEqual(startCommands.count, 2)
        XCTAssertTrue(startCommands.allSatisfy {
            $0.hasSuffix("'colima' 'start' '--profile' 'komodo-dev' '--activate=false' '--save-config=false'")
        })
    }

    @MainActor
    func testExtraForwardsSurviveProbeFailuresUntilProfileIsConfirmedStopped() async throws {
        let extra = try XCTUnwrap(LocalForward.parse("18080:8080"))
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev", forwards: extra))
        let publishedContainer = CommandResult(output: """
            {"ID":"abc000","Names":"web","State":"running","Ports":"0.0.0.0:3000->3000/tcp"}
            """, exitCode: 0)
        let dockerTimedOut = CommandResult(output: "Docker timed out", exitCode: 124, timedOut: true)
        let sshDown = CommandResult(output: "Connection refused", exitCode: 255)
        let stoppedProfile = CommandResult(output: #"{"name":"komodo-dev","status":"Stopped"}"#, exitCode: 0)
        let ssh = SSH([
            profileList, customSocket, publishedContainer,
            profileList, customSocket, dockerTimedOut,
            sshDown,
            stoppedProfile,
            sshDown,
            profileList, customSocket, dockerTimedOut,
        ])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        XCTAssertEqual(remote.tunnel.wanted, extra)

        remote.refresh()
        try await waitFor { remote.state == .ready }
        XCTAssertEqual(remote.tunnel.wanted.map(\.label), ["18080:8080", "3000:3000"])

        remote.refresh()
        try await waitFor { remote.state == .dockerUnavailable }
        XCTAssertEqual(remote.tunnel.wanted, extra)

        remote.refresh()
        try await waitFor { remote.state == .unreachable }
        XCTAssertEqual(remote.tunnel.wanted, extra)

        remote.refresh()
        try await waitFor { remote.state == .stopped }
        XCTAssertTrue(remote.tunnel.wanted.isEmpty)

        remote.refresh()
        try await waitFor { remote.state == .unreachable }
        XCTAssertTrue(remote.tunnel.wanted.isEmpty)

        remote.refresh()
        try await waitFor { remote.state == .dockerUnavailable }
        XCTAssertEqual(remote.tunnel.wanted, extra)
    }

    @MainActor
    func testStoppingProfileVerifiesStoppedRemovesForwardsAndStaysStopped() async throws {
        let forwards = try XCTUnwrap(LocalForward.parse("18080:8080"))
        let host = try XCTUnwrap(
            RemoteHost(name: "Sparky", alias: "sparky-local", profile: "default", forwards: forwards)
        )
        let bothRunning = CommandResult(output: """
            {"name":"default","status":"Running","cpus":4,"memory":8589934592}
            {"name":"komodo-dev","status":"Running","cpus":6,"memory":10737418240}
            """, exitCode: 0)
        let defaultSocket = CommandResult(output: """
            {"docker_socket":"unix:///Users/joon/.colima/default/docker.sock"}
            """, exitCode: 0)
        let webRunning = CommandResult(output: """
            {"ID":"abcdef0123456789","Names":"web","State":"running","Status":"Up 1 hour","Ports":"0.0.0.0:3000->3000/tcp"}
            """, exitCode: 0)
        let defaultStoppedOnly = CommandResult(output: """
            {"name":"default","status":"Stopped","cpus":4,"memory":8589934592}
            {"name":"komodo-dev","status":"Running","cpus":6,"memory":10737418240}
            """, exitCode: 0)

        let ssh = SSH([
            bothRunning, defaultSocket, webRunning,
            .init(output: "stopped", exitCode: 0),
            defaultStoppedOnly,
            defaultStoppedOnly,
        ])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })

        remote.refresh()
        try await waitFor { remote.state == .ready }
        XCTAssertEqual(remote.tunnel.wanted.map(\.label), ["18080:8080", "3000:3000"])

        remote.stopVM()
        try await waitFor { !remote.isActing }
        XCTAssertEqual(remote.state, .stopped)
        XCTAssertNil(remote.operationError)
        XCTAssertTrue(remote.containers.isEmpty)
        XCTAssertTrue(remote.tunnel.wanted.isEmpty)

        // Subsequent poll leaves a deliberately stopped profile stopped.
        remote.refresh()
        for _ in 0..<200 where await ssh.commands.count < 6 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await waitFor { remote.state == .stopped }
        let commands = await ssh.commands
        XCTAssertEqual(commands.count, 6)
        XCTAssertTrue(commands[3].last?.hasSuffix("'colima' 'stop' '--profile' 'default'") == true)
    }

    @MainActor
    func testOverlappingLifecycleActionsAreIgnoredAndUnconfirmedStopReportsError() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let ssh = SSH([
            profileList, customSocket, runningContainer,
            // colima stop exits 0, yet Colima still reports the profile as Running
            .init(output: "", exitCode: 0),
            profileList, customSocket, runningContainer,
        ])
        let remote = RemoteColima(host: host, runner: { args, _ in
            try? await Task.sleep(nanoseconds: 10_000_000)
            return await ssh.run(args)
        })

        remote.refresh()
        try await waitFor { remote.state == .ready }

        remote.stopVM()
        XCTAssertTrue(remote.isActing)
        XCTAssertEqual(remote.titleStatus, "Stopping…")
        // Overlapping calls while acting must be ignored.
        remote.stopVM()
        remote.restartVM()
        remote.startVM()
        remote.changeContainer(id: "0123456789abcdef", start: false)

        try await waitFor { !remote.isActing }
        XCTAssertEqual(remote.state, .ready)
        XCTAssertEqual(remote.operationError, "Stop komodo-dev not confirmed: profile is still running")
        let commands = await ssh.commands
        XCTAssertEqual(commands.count, 7)
    }

    @MainActor
    func testDistinctUnavailableStatesAndLifecycleEligibility() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "sparky-local", profile: "komodo-dev"))
        let ssh = SSH([
            // 1. SSH timed out before Colima answered
            .init(output: "No response within 10 seconds", exitCode: 124, timedOut: true),
            // 2. Colima CLI missing on remote
            .init(output: "env: colima: No such file or directory", exitCode: 127),
            // 3. Colima works, but selected profile does not exist
            .init(output: #"{"name":"default","status":"Running"}"#, exitCode: 0),
            // 4. Selected profile exists in Broken state -> recoverable via Stop/Restart
            .init(output: #"{"name":"komodo-dev","status":"Broken","cpus":6,"memory":10737418240}"#, exitCode: 0),
        ])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })

        remote.refresh()
        try await waitFor { remote.state == .unreachable }
        XCTAssertEqual(remote.titleStatus, "SSH unavailable")
        XCTAssertFalse(remote.canStartVM)
        XCTAssertFalse(remote.canStopVM)
        XCTAssertFalse(remote.canRestartVM)
        remote.startVM()
        remote.stopVM()
        remote.restartVM()

        remote.refresh()
        try await waitFor { remote.state == .colimaUnavailable }
        XCTAssertEqual(remote.titleStatus, "Colima unavailable")
        XCTAssertEqual(remote.error, "env: colima: No such file or directory")
        XCTAssertFalse(remote.canStartVM)
        XCTAssertFalse(remote.canStopVM)

        remote.refresh()
        try await waitFor { remote.state == .profileUnavailable }
        XCTAssertEqual(remote.titleStatus, "Profile not found")
        XCTAssertEqual(remote.error, #"Colima profile "komodo-dev" was not found on Sparky"#)
        XCTAssertFalse(remote.canStartVM, "missing profile must not offer Start and create an unconfigured VM")
        XCTAssertFalse(remote.canStopVM)

        remote.refresh()
        try await waitFor { remote.titleStatus == "Broken" }
        XCTAssertEqual(remote.state, .profileUnavailable)
        XCTAssertFalse(remote.canStartVM)
        XCTAssertTrue(remote.canStopVM)
        XCTAssertTrue(remote.canRestartVM)

        let commands = await ssh.commands
        XCTAssertEqual(commands.count, 4, "disabled lifecycle calls while unreachable/missing send no SSH commands")
    }

    @MainActor
    func testRemoteMenuAndConfirmationAlertIdentifyHostAndProfile() async throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "worker@sparky-local", profile: "komodo-dev"))
        let stoppedList = CommandResult(output: #"{"name":"komodo-dev","status":"Stopped","cpus":6,"memory":10737418240}"#, exitCode: 0)
        let dockerDown = CommandResult(output: "Cannot connect to the Docker daemon", exitCode: 1)
        let sshDown = CommandResult(output: "Connection refused", exitCode: 255)

        let ssh = SSH([
            stoppedList,
            profileList, customSocket, dockerDown,
            profileList, customSocket, runningContainer,
            sshDown,
        ])
        let remote = RemoteColima(host: host, runner: { args, _ in await ssh.run(args) })
        let delegate = AppDelegate()

        // 1. Stopped -> Start offered in section and in Connection Controls
        remote.refresh()
        try await waitFor { remote.state == .stopped }
        let stoppedMenu = NSMenu()
        delegate.addRemoteSection(remote, to: stoppedMenu)
        XCTAssertTrue(stoppedMenu.items.contains { $0.title == "Start komodo-dev VM" && $0.isEnabled })
        let stoppedControls = try XCTUnwrap(stoppedMenu.item(withTitle: "Connection Controls")?.submenu)
        XCTAssertTrue(stoppedControls.items.contains { $0.title == "Start komodo-dev VM" && $0.isEnabled })

        // 2. Running with unresponsive Docker -> Restart in section, Restart & Stop in Connection Controls
        remote.refresh()
        try await waitFor { remote.state == .dockerUnavailable }
        let brokenDockerMenu = NSMenu()
        delegate.addRemoteSection(remote, to: brokenDockerMenu)
        XCTAssertTrue(brokenDockerMenu.items.contains { $0.title == "⚠︎ Docker unavailable" })
        XCTAssertTrue(brokenDockerMenu.items.contains { $0.title == "Restart komodo-dev VM…" && $0.isEnabled })
        let brokenControls = try XCTUnwrap(brokenDockerMenu.item(withTitle: "Connection Controls")?.submenu)
        XCTAssertTrue(brokenControls.items.contains { $0.title == "Restart komodo-dev VM…" && $0.isEnabled })
        XCTAssertTrue(brokenControls.items.contains { $0.title == "Stop komodo-dev VM…" && $0.isEnabled })

        // 3. Online -> containers at top level; Restart & Stop stay inside Connection Controls only
        remote.refresh()
        try await waitFor { remote.state == .ready }
        let onlineMenu = NSMenu()
        delegate.addRemoteSection(remote, to: onlineMenu)
        XCTAssertFalse(onlineMenu.items.contains { $0.title.contains("Restart") || $0.title.contains("Stop") })
        let onlineControls = try XCTUnwrap(onlineMenu.item(withTitle: "Connection Controls")?.submenu)
        XCTAssertTrue(onlineControls.items.contains { $0.title == "Restart komodo-dev VM…" && $0.isEnabled })
        XCTAssertTrue(onlineControls.items.contains { $0.title == "Stop komodo-dev VM…" && $0.isEnabled })

        // 4. SSH unavailable -> connection failure shown, lifecycle disabled
        remote.refresh()
        try await waitFor { remote.state == .unreachable }
        let offlineMenu = NSMenu()
        delegate.addRemoteSection(remote, to: offlineMenu)
        XCTAssertTrue(offlineMenu.items.contains { $0.title == "⚠︎ SSH unavailable" })
        let offlineControls = try XCTUnwrap(offlineMenu.item(withTitle: "Connection Controls")?.submenu)
        XCTAssertTrue(offlineControls.items.contains {
            $0.title == "VM controls unavailable while SSH is offline" && !$0.isEnabled
        })
        XCTAssertFalse(offlineControls.items.contains {
            ($0.title.hasPrefix("Start ") || $0.title.hasPrefix("Stop ") || $0.title.hasPrefix("Restart ")) && $0.isEnabled
        })

        // 5. Stop & Restart confirmation alerts identify host, SSH alias, and profile
        let stopAlert = AppDelegate.lifecycleConfirmationAlert(for: host, stop: true)
        XCTAssertEqual(stopAlert.messageText, "Stop komodo-dev VM on Sparky?")
        XCTAssertTrue(stopAlert.informativeText.contains("komodo-dev"))
        XCTAssertTrue(stopAlert.informativeText.contains("Sparky"))
        XCTAssertTrue(stopAlert.informativeText.contains("worker@sparky-local"))
        XCTAssertEqual(stopAlert.buttons.map(\.title), ["Stop komodo-dev VM", "Cancel"])
        XCTAssertTrue(stopAlert.buttons.first?.hasDestructiveAction == true)

        let restartAlert = AppDelegate.lifecycleConfirmationAlert(for: host, stop: false)
        XCTAssertEqual(restartAlert.messageText, "Restart komodo-dev VM on Sparky?")
        XCTAssertTrue(restartAlert.informativeText.contains("komodo-dev"))
        XCTAssertEqual(restartAlert.buttons.map(\.title), ["Restart komodo-dev VM", "Cancel"])
    }

    func testHostMayNameTheAccountToLogInAs() throws {
        let host = try XCTUnwrap(RemoteHost(name: "Sparky", alias: "worker@sparky-local", profile: "offload"))
        XCTAssertEqual(host.ssh(["true"]).dropLast().last, "worker@sparky-local")
        XCTAssertNil(RemoteHost(name: "Sparky", alias: "-oProxyCommand=x@sparky-local", profile: "offload"))
        XCTAssertNil(RemoteHost(name: "Sparky", alias: "worker@-F", profile: "offload"))
        XCTAssertNil(RemoteHost(name: "Sparky", alias: "@sparky-local", profile: "offload"))
        XCTAssertNil(RemoteHost(name: "Sparky", alias: "worker@", profile: "offload"))
        XCTAssertNil(RemoteHost(name: "Sparky", alias: "a@b@sparky-local", profile: "offload"))
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
