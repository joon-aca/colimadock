import AppKit

@MainActor
final class RemoteConnectionForm: NSObject {
    // Sparky's VMs belong to its worker account (see sparky-vm); `offload` is the everyday one.
    static let sparkyAlias = "worker@sparky-local"
    static let sparkyProfile = "offload"

    let name = NSTextField(string: "")
    let alias = NSTextField(string: "")
    let profile = NSTextField(string: "default")
    let forwards = NSTextField(string: "")
    let view: NSGridView

    init(existing: RemoteHost?, offersSparky: Bool) {
        let preset = NSPopUpButton(frame: .zero, pullsDown: false)
        var rows: [[NSView]] = []
        if offersSparky {
            preset.addItems(withTitles: ["Sparky", "Custom server"])
            rows.append([NSTextField(labelWithString: "Server"), preset])
        }
        rows += [
            [NSTextField(labelWithString: "Name"), name],
            [NSTextField(labelWithString: "SSH host"), alias],
            [NSTextField(labelWithString: "Colima profile"), profile],
            [NSTextField(labelWithString: "Localhost forwards"), forwards],
        ]
        view = NSGridView(views: rows)
        super.init()

        name.placeholderString = "Office Mac"
        alias.placeholderString = "user@office-mac.local"
        forwards.placeholderString = "Optional, e.g. 29120:19120"
        name.setAccessibilityLabel("Name")
        alias.setAccessibilityLabel("SSH host")
        profile.setAccessibilityLabel("Colima profile")
        forwards.setAccessibilityLabel("Localhost forwards")
        for field in [name, alias, profile, forwards] {
            field.widthAnchor.constraint(equalToConstant: 230).isActive = true
        }

        if let existing {
            name.stringValue = existing.name
            alias.stringValue = existing.alias
            profile.stringValue = existing.profile
            forwards.stringValue = existing.forwards?.map(\.label).joined(separator: ", ") ?? ""
        } else if offersSparky {
            preset.setAccessibilityLabel("Server")
            preset.target = self
            preset.action = #selector(selectServer(_:))
            selectServer(preset)
        }

        view.columnSpacing = 12
        view.rowSpacing = 8
        // NSAlert sizes its accessory using the view's frame, which starts at zero for NSGridView.
        view.setFrameSize(view.fittingSize)
    }

    @objc private func selectServer(_ sender: NSPopUpButton) {
        let isSparky = sender.indexOfSelectedItem == 0
        name.stringValue = isSparky ? "Sparky" : ""
        alias.stringValue = isSparky ? Self.sparkyAlias : ""
        profile.stringValue = isSparky ? Self.sparkyProfile : "default"
        forwards.stringValue = ""
    }
}
