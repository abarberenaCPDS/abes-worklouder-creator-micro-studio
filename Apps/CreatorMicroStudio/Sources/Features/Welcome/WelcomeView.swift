import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?

    static func showOnManualLaunchIfNeeded() {
        // Keep login-item launches quiet. The welcome window is always
        // available from the menu-bar panel when the user wants it.
        guard SMAppService.mainApp.status != .enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            shared.show()
        }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(
            onOpenStudio: { [weak self] in
                self?.window?.close()
                StudioWindowController.shared.show(runtime: .shared)
            },
            onDismiss: { [weak self] in self?.window?.close() }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct WelcomeView: View {
    let onOpenStudio: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Image("StudioAppIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 156, height: 156)
                    .accessibilityLabel("Abe’s WorkLouder Creator Micro Studio app icon")

                Spacer().frame(height: 26)

                Text("Abe's WorkLouder")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("Creator Micro Studio")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 12)

                Text("A personal map for a remarkable little device.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(36)
            .background(.regularMaterial)

            VStack(alignment: .leading, spacing: 20) {
                Text("Make the Micro yours.")
                    .font(.title2.weight(.semibold))
                Text("See your agents at a glance, tune the pad, and shape the way your work feels.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    (Text("All work & ") + Text("no").strikethrough() + Text(" play"))
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("Human after all").font(.headline)
                        Text(verbatim: #"¯\_(ツ)_/¯"#)
                            .font(.title3)
                            .accessibilityLabel("shrug")
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                Spacer(minLength: 4)

                Label("Studio lives in your menu bar", systemImage: "menubar.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(action: onOpenStudio) {
                    Label("Open Studio", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue to the menu bar", action: onDismiss)
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
            }
            .frame(minWidth: 310, idealWidth: 310, maxWidth: 310,
                   maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview("Splash Window · 760×560") {
    WelcomeView(onOpenStudio: {}, onDismiss: {})
        .frame(width: 760, height: 560)
}
