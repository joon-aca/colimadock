import AppKit
import Combine
import SwiftUI

@main
struct ColimaDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var runtime: ColimaRuntime!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = ColimaRuntime()
        setupStatusItem()
        setupMenu()

        runtime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusIcon()
                    self?.setupMenu()
                }
            }
            .store(in: &cancellables)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let accessibilityLabel: String

        if runtime.isTransitioning {
            symbolName = "shippingbox.and.arrow.backward.fill"
            accessibilityLabel = "ColimaDock Transitioning"
        } else if !runtime.vm.status.isRunning {
            symbolName = "shippingbox"
            accessibilityLabel = "Colima VM Stopped"
        } else if runtime.hasRunningContainer {
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

        if runtime.isLoading {
            addDisabledItem("Loading...", to: menu)
        } else if !runtime.vm.status.isRunning {
            addVMUnavailableItems(to: menu)
        } else if runtime.containers.isEmpty {
            addDisabledItem("No containers found", to: menu)
        } else {
            for container in runtime.containers {
                menu.addItem(menuItem(for: container))
            }
        }

        if let error = runtime.lastError {
            menu.addItem(NSMenuItem.separator())
            addDisabledItem("Error: \(shortError(error))", to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(vmMenuItem())

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshStatus), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit ColimaDock", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addVMUnavailableItems(to menu: NSMenu) {
        addDisabledItem("Colima VM default: \(runtime.vm.status.displayName)", to: menu)

        if runtime.vm.status.isTransitioning {
            addDisabledItem(runtime.vm.status.displayName, to: menu)
            return
        }

        let startItem = NSMenuItem(title: "Start Colima", action: #selector(startVM), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
    }

    private func menuItem(for container: Container) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        addDisabledItem("Status: \(container.isTransitioning ? "Working..." : container.state.displayName)", to: submenu)
        addDisabledItem("Image: \(container.image)", to: submenu)
        addDisabledItem("ID: \(container.shortID)", to: submenu)

        if !container.status.isEmpty {
            addDisabledItem("Detail: \(container.status)", to: submenu)
        }

        if !container.ports.isEmpty {
            addDisabledItem("Ports: \(container.ports)", to: submenu)
        }

        if let stats = container.stats {
            submenu.addItem(NSMenuItem.separator())
            addDisabledItem("CPU: \(stats.cpuPercent)", to: submenu)
            addDisabledItem("Memory: \(stats.memoryUsage) (\(stats.memoryPercent))", to: submenu)
            addDisabledItem("Network: \(stats.networkIO)", to: submenu)
            addDisabledItem("Block I/O: \(stats.blockIO)", to: submenu)
            addDisabledItem("PIDs: \(stats.pids)", to: submenu)
        }

        submenu.addItem(NSMenuItem.separator())
        if container.isTransitioning {
            addDisabledItem("Working...", to: submenu)
        } else if container.state.canStop {
            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopContainer(_:)), keyEquivalent: "")
            stopItem.target = self
            stopItem.representedObject = container.id
            submenu.addItem(stopItem)
        } else if container.state.canStart {
            let startItem = NSMenuItem(title: "Start", action: #selector(startContainer(_:)), keyEquivalent: "")
            startItem.target = self
            startItem.representedObject = container.id
            submenu.addItem(startItem)
        } else {
            addDisabledItem("No action available", to: submenu)
        }

        let statusIcon = container.state.isRunning ? "●" : "○"
        let item = NSMenuItem(title: "\(statusIcon) \(container.name)", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func vmMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        addDisabledItem("Profile: default", to: submenu)
        addDisabledItem("Status: \(runtime.vm.status.displayName)", to: submenu)
        addDisabledItem("Arch: \(runtime.vm.arch)", to: submenu)
        addDisabledItem("CPUs: \(runtime.vm.cpus)", to: submenu)
        addDisabledItem("Memory: \(runtime.vm.memoryFormatted)", to: submenu)
        addDisabledItem("Disk: \(runtime.vm.diskFormatted)", to: submenu)

        submenu.addItem(NSMenuItem.separator())
        if runtime.vm.status.isTransitioning {
            addDisabledItem(runtime.vm.status.displayName, to: submenu)
        } else if runtime.vm.status.isRunning {
            let stopItem = NSMenuItem(title: "Stop Colima", action: #selector(stopVM), keyEquivalent: "")
            stopItem.target = self
            submenu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: "Start Colima", action: #selector(startVM), keyEquivalent: "")
            startItem.target = self
            submenu.addItem(startItem)
        }

        let item = NSMenuItem(title: "Colima VM", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func addDisabledItem(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
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

    @objc private func startContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runtime.startContainer(id: id)
    }

    @objc private func stopContainer(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runtime.stopContainer(id: id)
    }

    @objc private func refreshStatus() {
        runtime.refresh()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
