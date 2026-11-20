import AppKit
import Combine

// Plain AppKit, no SwiftUI `App`: a SwiftUI app whose only scene is `Settings`
// opens an empty Settings window at every launch.
@main
enum ColimaDockMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "docker" {
            let dockerArguments = Array(arguments.dropFirst())
            Task.detached { await DockerCommand.run(dockerArguments) }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct Target {
        let remote: RemoteColima
        let containerID: String
    }
    private struct LocalTarget {
        let profile: String
        let containerID: String
    }

    private var statusItem: NSStatusItem!
    private var runtime: ColimaRuntime!
    private var cancellables = Set<AnyCancellable>()
    private var localProfiles: [String: ColimaRuntime] = [:]
    private var localObservers: [String: AnyCancellable] = [:]
    private var remotes: [RemoteColima] = []
    private var remoteObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var dockerPreference: DockerPreference?
    private var menuUpdateQueued = false
    private var signalSources: [DispatchSourceSignal] = []
    private var leftoverTunnelsStopped = false
    private lazy var aboutPanel = AboutPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = ColimaRuntime()
        dockerPreference = DockerPreference.load(from: .standard)
        quitOnTerminationSignals()
        setupStatusItem()
        setupMenu()

        loadSavedRemotes()
        // Free the ports a killed or crashed instance's tunnels still hold before ours open.
        Task {
            await RemoteTunnel.stopLeftovers()
            leftoverTunnelsStopped = true
            remotes.forEach { $0.tunnel.start() }
        }

        runtime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.requestMenuUpdate() }
            .store(in: &cancellables)
        runtime.$otherDockerProfiles
            .sink { [weak self] in self?.syncLocalProfiles($0) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        remotes.forEach { $0.tunnel.stop() }
    }

    /// `kill`, `pkill` (as `make run` uses), logout and Ctrl-C quit normally instead of exiting
    /// on the spot, so `applicationWillTerminate` stops the SSH tunnels. Otherwise they outlive
    /// the app and keep its ports on this Mac.
    private func quitOnTerminationSignals() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    private func loadSavedRemotes() {
        guard let data = UserDefaults.standard.data(forKey: RemoteHost.defaultsKey),
              let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data) else { return }
        for saved in hosts {
            if let host = RemoteHost(name: saved.name, alias: saved.alias, profile: saved.profile, forwards: saved.forwards ?? []) {
                addRemote(host)
            }
        }
        requestMenuUpdate()
    }

    private func requestMenuUpdate() {
        guard !menuUpdateQueued else { return }
        menuUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.menuUpdateQueued = false
            self.updateStatusIcon()
            self.setupMenu()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let accessibilityLabel: String

        if runtime.isTransitioning || localProfiles.values.contains(where: \.isTransitioning) || remotes.contains(where: \.isActing) {
            symbolName = "shippingbox.and.arrow.backward.fill"
            accessibilityLabel = "ColimaDock Transitioning"
        } else if runtime.hasRunningContainer || localProfiles.values.contains(where: \.hasRunningContainer)
                    || remotes.contains(where: { $0.containers.contains(where: { $0.state.isRunning }) }) {
            symbolName = "shippingbox.fill"
            accessibilityLabel = "Containers Running"
        } else {
            symbolName = "shippingbox"
            accessibilityLabel = "No Containers Running"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel) {
            image.isTemplate = true
            button.image = image
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        addSectionHeader("This Mac", to: menu)
        addLocalProfile(runtime, to: menu)
        menu.addItem(defaultVMMenuItem())
        for profile in localProfiles.values.sorted(by: { $0.profile < $1.profile }) {
            menu.addItem(.separator())
            addLocalProfile(profile, to: menu)
        }
        addOrphanedProcessItems(to: menu)

        // Each remote is its own section, laid out like a local profile under This Mac.
        for remote in remotes {
            menu.addItem(.separator())
            addRemoteSection(remote, to: menu)
        }

        menu.addItem(.separator())
        addAction("Add Remote Colima…", #selector(addRemoteHost), to: menu)
        if !remotes.isEmpty { menu.addItem(dockerCommandsMenuItem()) }

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshStatus), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())
        addAction("About ColimaDock", #selector(showAboutPanel), to: menu)
        let quitItem = NSMenuItem(title: "Quit ColimaDock", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Opening the menu is the moment to catch remotes up; see `RemoteColima.menuWillOpen`.
    func menuWillOpen(_ menu: NSMenu) {
        remotes.forEach { $0.menuWillOpen() }
    }

    private func dockerCommandsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Docker Commands", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let preferred = remotes.first { DockerPreference($0.host) == dockerPreference }
        if let preferred {
            addDisabledItem("Prefer \(preferred.host.name); fall back to this Mac’s \(preferred.host.profile) VM", to: submenu)
        } else {
            addDisabledItem("Choose a preferred host", to: submenu)
        }
        for remote in remotes {
            addAction("\(remote.host.name) (\(remote.host.profile))", #selector(preferDockerHost(_:)),
                      to: submenu, representedBy: remote)
            submenu.items.last?.state = remote === preferred ? .on : .off
        }
        submenu.addItem(.separator())
        addAction("Copy Docker Command Prefix", #selector(copyDockerCommand), to: submenu, enabled: preferred != nil)
        item.submenu = submenu
        return item
    }

    @objc private func preferDockerHost(_ sender: NSMenuItem) {
        guard let remote = sender.representedObject as? RemoteColima,
              remotes.contains(where: { $0 === remote }) else { return }
        setDockerPreference(DockerPreference(remote.host))
    }

    private func setDockerPreference(_ preference: DockerPreference?) {
        dockerPreference = preference
        if let preference {
            preference.save(to: .standard)
        } else {
            UserDefaults.standard.removeObject(forKey: DockerPreference.defaultsKey)
        }
        requestMenuUpdate()
    }

    @objc private func copyDockerCommand() {
        guard let executable = Bundle.main.executablePath else { return }
        let path = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString("\(path) docker -- ", forType: .string)
    }

    /// Start always clears stale locks first (see ColimaRuntime.startVM); the label just says so.
    private func addStartVMItems(to menu: NSMenu) {
        let hasStaleLocks = !runtime.staleDiskLocks.isEmpty
        let lockNoun = runtime.staleDiskLocks.count > 1 ? "Locks" : "Lock"

        let startItem = NSMenuItem(
            title: hasStaleLocks ? "Clear \(lockNoun) & Start default VM" : "Start default VM",
            action: #selector(startVM),
            keyEquivalent: ""
        )
        startItem.target = self
        menu.addItem(startItem)

        if hasStaleLocks {
            let clearItem = NSMenuItem(title: "Clear \(lockNoun) Only", action: #selector(clearStaleDiskLocks), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }
    }

    private func addOrphanedProcessItems(to menu: NSMenu) {
        guard !runtime.orphanedProcesses.isEmpty else { return }

        menu.addItem(NSMenuItem.separator())
        addDisabledItem("⚠︎ Leftover Colima processes", to: menu)

        for orphan in runtime.orphanedProcesses {
            menu.addItem(menuItem(for: orphan))
        }

        if runtime.orphanedProcesses.count > 1 {
            let stopAllItem = NSMenuItem(title: "Stop All Leftover Processes", action: #selector(stopAllOrphanedProcesses), keyEquivalent: "")
            stopAllItem.target = self
            stopAllItem.isEnabled = runtime.stoppingOrphans.isEmpty
            menu.addItem(stopAllItem)
        }
    }

    private func menuItem(for orphan: OrphanedProcess) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let started = DateFormatter.localizedString(from: orphan.startDate, dateStyle: Calendar.current.isDateInToday(orphan.startDate) ? .none : .short, timeStyle: .short)
        addDisabledItem("\(orphan.kind.purpose), left running since \(started)", to: submenu)
        addDisabledItem("Colima lost track of it and won't stop it", to: submenu)

        submenu.addItem(NSMenuItem.separator())
        if runtime.stoppingOrphans.contains(orphan.pid) {
            addDisabledItem("Stopping...", to: submenu)
        } else {
            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopOrphanedProcess(_:)), keyEquivalent: "")
            stopItem.target = self
            stopItem.representedObject = NSNumber(value: orphan.pid)
            submenu.addItem(stopItem)
        }

        let item = NSMenuItem(title: "  \(orphan.kind.title) (\(orphan.target))", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func menuItem(for container: Container, remote: RemoteColima? = nil, localProfile: String? = nil) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        addDisabledItem("Status: \(container.isTransitioning ? "Working..." : container.state.displayName)", to: submenu)
        addDisabledItem("Image: \(container.image)", to: submenu)
        addDisabledItem("ID: \(container.shortID)", to: submenu)

        if !container.status.isEmpty {
            addDisabledItem("Detail: \(container.status)", to: submenu)
        }

        if !container.ports.isEmpty {
            addDisabledItem("\(remote == nil ? "Ports" : "Ports on remote host"): \(container.ports)", to: submenu)
        }
        if let remote, container.state.isRunning {
            for port in PublishedPorts.tcp(container.ports) { addForwardItem(port, remote: remote, to: submenu) }
        }

        if let stats = container.stats {
            submenu.addItem(NSMenuItem.separator())
            // Remote stats are a sample from the last menu open or Refresh, not live.
            if let sampled = remote?.statsAt {
                addDisabledItem("Stats from \(sampled.formatted(date: .omitted, time: .standard))", to: submenu)
            }
            addDisabledItem("CPU: \(stats.cpuPercent)", to: submenu)
            addDisabledItem("Memory: \(stats.memoryUsage) (\(stats.memoryPercent))", to: submenu)
            addDisabledItem("Network: \(stats.networkIO)", to: submenu)
            addDisabledItem("Block I/O: \(stats.blockIO)", to: submenu)
            addDisabledItem("PIDs: \(stats.pids)", to: submenu)
        }

        submenu.addItem(NSMenuItem.separator())
        if container.isTransitioning || remote?.isActing == true {
            addDisabledItem("Working...", to: submenu)
        } else if container.state.canStop {
            if let remote {
                addAction("Stop on \(remote.host.name)", #selector(stopContainer(_:)), to: submenu,
                          representedBy: Target(remote: remote, containerID: container.id))
            } else if let localProfile {
                addAction("Stop", #selector(stopContainer(_:)), to: submenu,
                          representedBy: LocalTarget(profile: localProfile, containerID: container.id))
            } else {
                addAction("Stop", #selector(stopContainer(_:)), to: submenu, representedBy: container.id)
            }
        } else if container.state.canStart {
            if let remote {
                addAction("Start on \(remote.host.name)", #selector(startContainer(_:)), to: submenu,
                          representedBy: Target(remote: remote, containerID: container.id))
            } else if let localProfile {
                addAction("Start", #selector(startContainer(_:)), to: submenu,
                          representedBy: LocalTarget(profile: localProfile, containerID: container.id))
            } else {
                addAction("Start", #selector(startContainer(_:)), to: submenu, representedBy: container.id)
            }
        } else {
            addDisabledItem("No action available", to: submenu)
        }

        let item = NSMenuItem(title: "\(statusDot(container.state.isRunning)) \(container.name)", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func syncLocalProfiles(_ names: [String]) {
        let discovered = Set(names)
        for name in Set(localProfiles.keys).subtracting(discovered) {
            localProfiles.removeValue(forKey: name)?.stopRefreshing()
            localObservers.removeValue(forKey: name)
        }
        for name in names where localProfiles[name] == nil {
            let profile = ColimaRuntime(profile: name)
            localProfiles[name] = profile
            localObservers[name] = profile.objectWillChange
                .sink { [weak self] _ in self?.requestMenuUpdate() }
        }
        requestMenuUpdate()
    }

    private func addLocalProfile(_ profile: ColimaRuntime, to menu: NSMenu) {
        addDisabledItem("\(profile.profile) VM", to: menu)
        if profile.isLoading {
            addDisabledItem("Loading…", to: menu)
        } else if let error = profile.lastError {
            addDisabledItem(shortError(error), to: menu, detail: error)
        } else if !profile.vm.status.isRunning {
            addDisabledItem(profile.vm.status.displayName, to: menu)
        } else if profile.containers.isEmpty {
            addDisabledItem("No containers found", to: menu)
        } else {
            let localProfile = profile === runtime ? nil : profile.profile
            for container in profile.containers {
                menu.addItem(menuItem(for: container, localProfile: localProfile))
            }
        }
    }

    /// A remote's VM and containers at the top level, as `addLocalProfile` shows a local one,
    /// with the connection's details and actions in one submenu like `VM Controls`.
    private func addRemoteSection(_ remote: RemoteColima, to menu: NSMenu) {
        addSectionHeader(remote.host.name, to: menu)
        addDisabledItem("\(remote.host.profile) VM", to: menu)
        if remote.state != .ready {
            // A failure gets the warning mark so it doesn't read as merely stopped.
            let title = remote.state.isFailure ? "⚠︎ \(remote.titleStatus)" : remote.titleStatus
            addDisabledItem(title, to: menu, detail: remote.error)
        } else if remote.containers.isEmpty {
            addDisabledItem("No containers found", to: menu)
        } else {
            for container in remote.containers { menu.addItem(menuItem(for: container, remote: remote)) }
        }
        for error in [remote.operationError, remote.statsError].compactMap({ $0 }) {
            addDisabledItem("⚠︎ \(shortError(error))", to: menu, detail: error)
        }
        if case .retrying(let error) = remote.tunnel.status, !remote.tunnel.wanted.isEmpty {
            addDisabledItem("⚠︎ Ports on this Mac offline • retrying", to: menu, detail: error)
        }
        menu.addItem(remoteControlsMenuItem(remote))
    }

    private func remoteControlsMenuItem(_ remote: RemoteColima) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        addDisabledItem("Status: \(remote.titleStatus)", to: submenu)
        addDisabledItem("SSH: \(remote.host.alias) • Profile: \(remote.host.profile)", to: submenu)
        if let vm = remote.vm {
            addDisabledItem("VM: \(vm.status.displayName) • \(vm.cpus) CPUs • \(vm.memoryFormatted) RAM", to: submenu)
        }
        if let last = remote.lastOnline, remote.state != .ready {
            addDisabledItem("Last online: \(last.formatted(date: .abbreviated, time: .shortened))", to: submenu)
        }
        for error in [remote.error, remote.operationError, remote.statsError].compactMap({ $0 }) {
            addDisabledItem(shortError(error), to: submenu, detail: error)
        }
        let wanted = remote.tunnel.wanted
        if !wanted.isEmpty {
            submenu.addItem(.separator())
            switch remote.tunnel.status {
            case .off, .connecting:
                addDisabledItem("Connecting ports to this Mac…", to: submenu)
            case .forwarding:
                addDisabledItem("On this Mac:", to: submenu)
                for forward in wanted { addForwardItem(forward.localPort, remote: remote, to: submenu) }
            case .retrying(let error):
                addDisabledItem("Ports on this Mac offline • retrying", to: submenu)
                addDisabledItem(shortError(error), to: submenu, detail: error)
            }
        }
        submenu.addItem(.separator())
        addAction("Edit Connection…", #selector(editRemoteHost(_:)), to: submenu,
                  representedBy: remote, enabled: !remote.isActing)
        addAction("Forget Connection", #selector(forgetRemoteHost(_:)), to: submenu,
                  representedBy: remote, enabled: !remote.isActing)

        let item = NSMenuItem(title: "Connection Controls", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func defaultVMMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        addDisabledItem("Profile: default", to: submenu)
        addDisabledItem("Status: \(runtime.vm.status.displayName)", to: submenu)
        addDisabledItem("Arch: \(runtime.vm.arch)", to: submenu)
        addDisabledItem("CPUs: \(runtime.vm.cpus)", to: submenu)
        addDisabledItem("Memory: \(runtime.vm.memoryFormatted)", to: submenu)
        addDisabledItem("Disk: \(runtime.vm.diskFormatted)", to: submenu)

        submenu.addItem(NSMenuItem.separator())
        if runtime.isLoading || runtime.vm.status.isTransitioning {
            addDisabledItem(runtime.vm.status.displayName, to: submenu)
        } else if runtime.vm.status.isRunning {
            let stopItem = NSMenuItem(title: "Stop default VM", action: #selector(stopVM), keyEquivalent: "")
            stopItem.target = self
            submenu.addItem(stopItem)
        } else {
            for lock in runtime.staleDiskLocks {
                addDisabledItem("⚠︎ Leftover lock on disk \(lock.disk) will block starting", to: submenu)
            }
            addStartVMItems(to: submenu)
        }

        let item = NSMenuItem(title: "VM Controls (default)", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// One forwarded port: `localhost:5432 → postgres`, or why it isn't listening on this Mac.
    private func addForwardItem(_ port: UInt16, remote: RemoteColima, to menu: NSMenu) {
        let tunnel = remote.tunnel
        guard let forward = tunnel.wanted.first(where: { $0.localPort == port }) else { return }
        let container = forward.localPort == forward.remotePort ? tunnel.published[port] : nil
        let target = container ?? "\(remote.host.name):\(forward.remotePort)"
        if let reason = tunnel.blocked[port] {
            addDisabledItem("⚠︎ localhost:\(port) → \(target): \(shortError(reason))", to: menu, detail: reason)
        } else if tunnel.active.contains(forward) {
            addDisabledItem("localhost:\(port) → \(target)", to: menu)
        } else {
            addDisabledItem("localhost:\(port) → \(target) (connecting…)", to: menu)
        }
    }

    /// The status dot for container and remote VM rows: filled when running, hollow when not.
    private func statusDot(_ running: Bool) -> String { running ? "●" : "○" }

    private func addDisabledItem(_ title: String, to menu: NSMenu, detail: String? = nil) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = detail
        menu.addItem(item)
    }

    private func addSectionHeader(_ title: String, to menu: NSMenu) {
        if #available(macOS 14.0, *) {
            menu.addItem(.sectionHeader(title: title))
        } else {
            addDisabledItem(title, to: menu)
        }
    }

    private func addAction(_ title: String, _ action: Selector, to menu: NSMenu,
                           representedBy object: Any? = nil, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func shortError(_ error: String) -> String {
        let firstLine = error.components(separatedBy: .newlines).first ?? error
        if firstLine.count > 80 {
            return String(firstLine.prefix(77)) + "..."
        }
        return firstLine
    }

    @objc private func startVM() {
        runtime.startVM()
    }

    @objc private func stopVM() {
        runtime.stopVM()
    }

    @objc private func clearStaleDiskLocks() {
        runtime.clearStaleDiskLocks()
    }

    @objc private func stopOrphanedProcess(_ sender: NSMenuItem) {
        guard let pid = (sender.representedObject as? NSNumber)?.int32Value else { return }
        runtime.stopOrphanedProcess(pid: pid)
    }

    @objc private func stopAllOrphanedProcesses() {
        runtime.stopAllOrphanedProcesses()
    }

    @objc private func startContainer(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? Target, remotes.contains(where: { $0 === target.remote }) {
            target.remote.changeContainer(id: target.containerID, start: true)
            return
        }
        if let target = sender.representedObject as? LocalTarget {
            localProfiles[target.profile]?.startContainer(id: target.containerID)
            return
        }
        guard let id = sender.representedObject as? String else { return }
        runtime.startContainer(id: id)
    }

    @objc private func stopContainer(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? Target, remotes.contains(where: { $0 === target.remote }) {
            target.remote.changeContainer(id: target.containerID, start: false)
            return
        }
        if let target = sender.representedObject as? LocalTarget {
            localProfiles[target.profile]?.stopContainer(id: target.containerID)
            return
        }
        guard let id = sender.representedObject as? String else { return }
        runtime.stopContainer(id: id)
    }

    @objc private func refreshStatus() {
        runtime.refresh()
        localProfiles.values.forEach { $0.refresh() }
        remotes.forEach { $0.refresh(withStats: true) }
    }

    @objc private func addRemoteHost() { editConnection(nil) }

    @objc private func editRemoteHost(_ sender: NSMenuItem) {
        guard let remote = sender.representedObject as? RemoteColima, !remote.isActing else { return }
        editConnection(remote)
    }

    @objc private func forgetRemoteHost(_ sender: NSMenuItem) {
        guard let remote = sender.representedObject as? RemoteColima, !remote.isActing else { return }
        removeRemote(remote)
        if DockerPreference(remote.host) == dockerPreference { setDockerPreference(nil) }
        saveRemotes()
    }

    private func editConnection(_ existing: RemoteColima?) {
        let offersSparky = existing == nil && !remotes.contains {
            $0.host.alias == RemoteConnectionForm.sparkyAlias && $0.host.profile == RemoteConnectionForm.sparkyProfile
        }
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Remote Colima" : "Edit Remote Colima"
        alert.informativeText = offersSparky
            ? "Choose Sparky or enter a trusted SSH alias or hostname for another machine, as user@host to log in as another account."
            : "Use a trusted SSH alias or hostname, as user@host to log in as another account. Published container ports reach this Mac on the same localhost port automatically."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let form = RemoteConnectionForm(existing: existing?.host, offersSparky: offersSparky)
        alert.accessoryView = form.view
        alert.window.initialFirstResponder = form.name
        NSApp.activate(ignoringOtherApps: true)

        while alert.runModal() == .alertFirstButtonReturn {
            let trim = CharacterSet.whitespacesAndNewlines
            guard let mappings = LocalForward.parse(form.forwards.stringValue) else {
                alert.informativeText = "Enter local:remote port pairs such as 29120:19120, using each local port once (1024–65535)."
                continue
            }
            guard let host = RemoteHost(name: form.name.stringValue.trimmingCharacters(in: trim),
                                        alias: form.alias.stringValue.trimmingCharacters(in: trim),
                                        profile: form.profile.stringValue.trimmingCharacters(in: trim), forwards: mappings) else {
                alert.informativeText = "Enter a name, an SSH alias or hostname (optionally user@host), and a Colima profile."
                continue
            }
            guard !remotes.contains(where: { $0 !== existing && $0.host.alias == host.alias && $0.host.profile == host.profile }) else {
                alert.informativeText = "This SSH alias and profile are already in the menu."
                continue
            }
            let otherPorts = Set(remotes.filter { $0 !== existing }.flatMap { $0.host.forwards ?? [] }.map(\.localPort))
            guard otherPorts.isDisjoint(with: mappings.map(\.localPort)) else {
                alert.informativeText = "Choose a local port that isn’t already assigned to another connection in ColimaDock."
                continue
            }
            if existing?.host == host { break }
            if let existing {
                if DockerPreference(existing.host) == dockerPreference { setDockerPreference(DockerPreference(host)) }
                removeRemote(existing)
            }
            addRemote(host)
            saveRemotes()
            break
        }
    }

    private func addRemote(_ host: RemoteHost) {
        let remote = RemoteColima(host: host)
        remotes.append(remote)
        remoteObservers[ObjectIdentifier(remote)] = remote.objectWillChange
            .merge(with: remote.tunnel.objectWillChange)
            .sink { [weak self] _ in self?.requestMenuUpdate() }
        remote.startRefreshing()
        if leftoverTunnelsStopped { remote.tunnel.start() }
    }

    private func removeRemote(_ remote: RemoteColima) {
        remote.stopRefreshing()
        remote.tunnel.stop()
        remoteObservers.removeValue(forKey: ObjectIdentifier(remote))
        remotes.removeAll { $0 === remote }
    }

    private func saveRemotes() {
        if let data = try? JSONEncoder().encode(remotes.map(\.host)) {
            UserDefaults.standard.set(data, forKey: RemoteHost.defaultsKey)
        }
        requestMenuUpdate()
    }

    @objc private func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        aboutPanel.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
