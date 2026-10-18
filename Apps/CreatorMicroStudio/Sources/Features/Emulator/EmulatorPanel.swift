import AppKit
import SwiftUI
import CreatorMicroStudioKit

/// A window showing the virtual pad: the lights the bridge is driving, and
/// keys you can press back at it.
///
/// It is a plain resizable window rather than a floating panel, because
/// unlike the model panel this one is meant to be clicked, sat beside your
/// editor, and left open.
@MainActor
final class EmulatorWindowController: NSObject, NSWindowDelegate {
    static let shared = EmulatorWindowController()

    private var window: NSWindow?

    func show(_ emulator: PadEmulator) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Creator Micro 2 — emulated"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: EmulatorView(emulator: emulator))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct EmulatorView: View {
    @ObservedObject var emulator: PadEmulator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pad
            Divider()
            controls
            Divider()
            traffic
        }
        .padding(16)
        .frame(minWidth: 340, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - The pad

    private var pad: some View {
        VStack(spacing: 8) {
            // The ambient ring, which the bridge drives with the worst state
            // across every agent.
            RoundedRectangle(cornerRadius: 14)
                .fill(zoneColor(emulator.ambientZone))
                .frame(height: 8)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))

            VStack(spacing: Self.gap) {
                ForEach(Array(Pad.physicalDisplayRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: Self.gap) {
                        ForEach(row) { cell in displayCell(cell) }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
        }
    }

    static let keyW: CGFloat = 52
    static let keyH: CGFloat = 40
    static let gap: CGFloat = 6

    @ViewBuilder
    private func displayCell(_ cell: Pad.DisplayCell) -> some View {
        switch cell {
        case .key(let key): keyButton(key)
        case .dial: dial
        case .joystick: joystick
        case .caseMark: caseMark
        }
    }

    private var caseMark: some View {
        Circle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 22, height: 22)
            .frame(width: Self.keyW, height: Self.keyH)
            .accessibilityLabel("Circular case mark, not a key")
    }

    private func keyButton(_ key: Int) -> some View {
        let state = emulator.keys[key]
        let lit = state?.isLit == true && emulator.bound.contains(key)
        return Button {
            emulator.press(key)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(lit ? Color(packedRGB: state?.color ?? 0)
                          : Color.white.opacity(emulator.bound.contains(key) ? 0.10 : 0.04))
                .frame(width: Self.keyW, height: Self.keyH)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                )
                .overlay(
                    Text("\(key)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(lit ? .black.opacity(0.55) : .white.opacity(0.35))
                        .padding(3),
                    alignment: .topLeading
                )
        }
        .buttonStyle(.plain)
        .help(helpText(key))
    }

    private func helpText(_ key: Int) -> String {
        guard emulator.bound.contains(key) else {
            return "Key \(key) — not bound to KV_OAI_AG*, so it sends a keystroke and cannot light"
        }
        guard let state = emulator.keys[key], state.isLit else { return "Key \(key) — dark" }
        return "Key \(key) — \(hexString(state.color)), \(state.effect.label.lowercased())"
    }

    private var dial: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.18))
                .frame(width: 36, height: 36)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            Capsule()
                .fill(Color.white.opacity(0.75))
                .frame(width: 3, height: 8)
                .offset(y: -13)
            HStack(spacing: 4) {
                Button { emulator.press(Pad.dialDownID) } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Rotate counter-clockwise")
                Button { emulator.press(Pad.dialPushID) } label: {
                    Image(systemName: "smallcircle.filled.circle")
                }
                .help(emulator.bound.contains(Pad.dialPushID)
                      ? "Push the dial"
                      : "Push the dial — not bound yet, so it sends play/pause instead")
                Button { emulator.press(Pad.dialUpID) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rotate clockwise")
            }
            .font(.system(size: 9, weight: .semibold))
            .buttonStyle(.plain)
        }
        .frame(width: Self.keyW, height: Self.keyH)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rotary dial")
    }

    private var joystick: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.16))
                .frame(width: 34, height: 34)
            Circle()
                .fill(Color.secondary.opacity(0.32))
                .frame(width: 10, height: 10)
            arrow("chevron.up", Pad.joyNorthID).offset(y: -13)
            arrow("chevron.left", Pad.joyWestID).offset(x: -14)
            arrow("chevron.right", Pad.joyEastID).offset(x: 14)
            arrow("chevron.down", Pad.joySouthID).offset(y: 13)
        }
        .frame(width: Self.keyW, height: Self.keyH)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Four-way joystick")
    }

    private func arrow(_ symbol: String, _ key: Int) -> some View {
        Button { emulator.press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 12, height: 12)
        }
        .buttonStyle(.plain)
        .help("Joystick — key \(key)")
    }

    private func zoneColor(_ zone: OAI.Zone) -> Color {
        guard zone.effect != .off, zone.brightness > 0 else { return Color.white.opacity(0.06) }
        return Color(packedRGB: zone.color)
    }

    // MARK: - Below the pad

    private var controls: some View {
        HStack {
            Label(
                emulator.bound.isEmpty
                    ? "Stock keymap — no key can light yet"
                    : "\(emulator.bound.count) keys bound to KV_OAI_AG*",
                systemImage: emulator.bound.isEmpty ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(emulator.bound.isEmpty ? .orange : .secondary)
            Spacer()
            Button("Reset") { emulator.reset() }
                .help("Back to a factory pad: stock keymap, every light off")
        }
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TRAFFIC")
                .font(.system(.caption2, design: .monospaced)).bold()
                .foregroundStyle(.tertiary).kerning(1.1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(emulator.traffic.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: emulator.traffic.count) { count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .frame(minHeight: 90)
        }
    }
}

#Preview("Virtual Creator Micro 2") {
    EmulatorView(emulator: PadEmulator())
        .frame(width: 480, height: 700)
}
