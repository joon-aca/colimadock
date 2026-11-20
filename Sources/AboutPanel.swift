import AppKit
import SwiftUI

@MainActor
final class AboutPanel: NSPanel {
    init() {
        let hostingController = NSHostingController(rootView: AboutContent())
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "About ColimaDock"
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentViewController = hostingController
        setContentSize(hostingController.view.fittingSize)
        center()
    }
}

private struct AboutContent: View {
    private let guideURL = URL(string: "https://github.com/joon-aca/colimadock#readme")!

    private var versionLabel: String? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("ColimaDock")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if let versionLabel {
                        Text(versionLabel)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text("Manage local and remote Docker containers from your menu bar.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            feature(
                "Manage local containers", symbol: "shippingbox",
                detail: "Open a container under **This Mac** to start or stop it. The default profile also shows CPU and memory snapshots."
            )
            feature(
                "Connect to remote Colima", symbol: "server.rack",
                detail: "Choose **Add Remote Colima…** and enter a trusted SSH host and Colima profile. Published ports forward to `localhost` while ColimaDock runs."
            )
            feature(
                "Run Docker commands on a remote", symbol: "terminal",
                detail: "Under **Docker Commands**, choose a preferred remote and select **Copy Docker Command Prefix**. Paste it in Terminal and append `ps`. If the remote is unavailable, ColimaDock tries the matching local profile."
            )

            Divider()

            HStack {
                if let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String {
                    Text(copyright)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("Open User Guide", destination: guideURL)
            }
        }
        .padding(24)
        .frame(width: 510)
    }

    private func feature(_ title: String, symbol: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
