import AppKit
import SwiftUI

/// The small floating text entry behind a Herdr command's `{ask:Prompt}`.
///
/// Unlike the status panels, this one takes keyboard focus — it exists to be
/// typed into — and hands focus back to the app that had it when it closes,
/// usually the terminal running Herdr. Return answers, Esc (or closing the
/// window) cancels, and a cancelled ask cancels the whole action silently.
@MainActor
final class HerdrAskPanel: NSObject, NSWindowDelegate {
    static let shared = HerdrAskPanel()

    private var panel: AskWindow?
    private var continuation: CheckedContinuation<String?, Never>?
    private var previousApp: NSRunningApplication?
    /// The app focus was last handed back to, and when. Activation is
    /// asynchronous, so an ask that follows straight on (a second `{ask:…}`
    /// in the same command) can still find this app frontmost.
    private var lastRestored: (app: NSRunningApplication, at: Date)?

    /// Shows the prompt and waits for the answer; nil when cancelled. A new
    /// ask while one is open cancels the open one first.
    func ask(prompt: String, defaultText: String) async -> String? {
        finish(nil, restoreFocus: false)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(prompt: prompt, defaultText: defaultText)
        }
    }

    private func present(prompt: String, defaultText: String) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        } else if previousApp == nil {
            // This app is frontmost only because an ask just had it (one
            // replaced while open keeps its previousApp; one that just
            // finished may not have handed focus back yet). Keep the app the
            // user came from rather than forgetting it.
            if let recent = lastRestored, Date().timeIntervalSince(recent.at) < 2, !recent.app.isTerminated {
                previousApp = recent.app
            }
        }
        lastRestored = nil

        let panel = AskWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 150),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Herdr command"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.finish(nil) }
        panel.contentView = NSHostingView(rootView: AskView(
            prompt: prompt,
            initialText: defaultText,
            onOK: { [weak self] text in self?.finish(text) },
            onCancel: { [weak self] in self?.finish(nil) }
        ))
        position(panel)
        self.panel = panel
        // An accessory app has to activate for its window to take typing.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + visible.height * 0.62))
    }

    private func finish(_ answer: String?, restoreFocus: Bool = true) {
        let continuation = self.continuation
        self.continuation = nil
        if let panel {
            self.panel = nil
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        if restoreFocus, let previousApp, !previousApp.isTerminated {
            previousApp.activate(options: [])
            lastRestored = (previousApp, Date())
        }
        if restoreFocus { previousApp = nil }
        continuation?.resume(returning: answer)
    }

    func windowWillClose(_ notification: Notification) {
        // Already closing: just let go of it, then cancel.
        panel?.delegate = nil
        panel = nil
        finish(nil)
    }

    /// Can become key without a full window chrome; Esc cancels.
    final class AskWindow: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }
}

private struct AskView: View {
    let prompt: String
    let initialText: String
    let onOK: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focused($fieldFocused)
                .onSubmit { onOK(text) }
            HStack {
                Text("Return to run · Esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("OK") { onOK(text) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 16)
        .frame(width: 460)
        .onAppear {
            text = initialText
            DispatchQueue.main.async { fieldFocused = true }
        }
    }
}

#Preview("Herdr Ask Panel") {
    AskView(prompt: "New tab name", initialText: "api server", onOK: { _ in }, onCancel: {})
}
