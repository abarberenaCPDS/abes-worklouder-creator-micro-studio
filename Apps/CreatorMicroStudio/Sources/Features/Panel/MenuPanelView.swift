import SwiftUI
import AppKit
import ServiceManagement
import CreatorMicroStudioKit

struct MenuPanelView: View {
    @EnvironmentObject var bridge: BridgeController
    @EnvironmentObject var runtime: StudioRuntimeCoordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if runtime.isInspectorActive || runtime.isTransitioning {
                inspectorActiveHint
            } else if bridge.permissionDenied {
                permissionBanner
            } else if bridge.isRunning {
                padSection
                Divider()
                agentSection
            } else {
                idleHint
            }

            if let error = bridge.lastError, !bridge.permissionDenied {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }

            if bridge.contendingClient {
                Divider()
                Label(
                    "Another app is also driving this pad — colours may fight.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 8)
            }

            Divider()
            footer
        }
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.displayName).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { BridgeSettings.enabled },
                set: { on in
                    Task { await runtime.setStudioEnabled(on) }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(BridgeSettings.enabled ? "Turn off Studio" : "Turn on Studio")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var subtitle: String {
        if runtime.isTransitioning { return "Switching the pad…" }
        if runtime.isInspectorActive { return "Inspector has the pad" }
        guard BridgeSettings.enabled else { return "Off" }
        guard bridge.isRunning else { return "Starting…" }
        guard bridge.deviceConnected else { return "Looking for the pad…" }
        var parts = [bridge.deviceName, bridge.firmware]
        if let battery = bridge.battery { parts.append(battery) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Pad

    private var padSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Pad.physicalDisplayRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { cell in displayCell(cell) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder
    private func displayCell(_ cell: Pad.DisplayCell) -> some View {
        switch cell {
        case .key(let index): keyView(index)
        case .dial: dialMarker
        case .joystick: joystickMarker
        case .caseMark: caseMark
        }
    }

    private var dialMarker: some View {
        Circle()
            .fill(Color.secondary.opacity(0.14))
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.7))
            .overlay(alignment: .top) {
                Capsule().fill(Color.secondary.opacity(0.65))
                    .frame(width: 2, height: 6).padding(.top, 4)
            }
            .frame(width: 24, height: 24)
            .frame(width: 34, height: 26)
            .accessibilityLabel("Rotary dial")
            .help(bindingHelp(.dial))
    }

    /// One line per input in the group, built from the current bindings.
    private func bindingHelp(_ group: Pad.InputGroup) -> String {
        group.inputs
            .map { "\($0.name): \(bridge.keyBindings.action(for: $0.id).summary)" }
            .joined(separator: "\n")
    }

    private var joystickMarker: some View {
        Circle()
            .fill(Color.secondary.opacity(0.14))
            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.28), lineWidth: 0.7))
            .overlay(Image(systemName: "xmark")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary))
            .frame(width: 24, height: 24)
            .frame(width: 34, height: 26)
            .accessibilityLabel("Joystick")
            .help(bindingHelp(.joystick))
    }

    private var caseMark: some View {
        Circle()
            .fill(Color.secondary.opacity(0.24))
            .frame(width: 17, height: 17)
            .frame(width: 34, height: 26)
            .accessibilityLabel("Case mark, not a key")
    }

    private func keyView(_ index: Int) -> some View {
        let color = bridge.keyColors[index]
        let isBound = Pad.boundKeyIDs.contains(index)
        let action = bridge.keyBindings.action(for: index)
        // Key index and agent slot are different orderings — the top row is
        // wired right to left — so the slot lookup goes through the pad map.
        let slot = Pad.agentSlot(for: index)
        let agent = slot.flatMap { $0 < bridge.agents.count ? bridge.agents[$0] : nil }

        return Button {
            bridge.handleKeyPress(index)
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(color ?? Color.secondary.opacity(isBound ? 0.16 : 0.07))
                .frame(width: 34, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(action == .none || (action == .focusAgent && Pad.agentSlot(for: index) != nil && agent == nil))
        .accessibilityLabel(helpText(index, agent: agent))
        .help(helpText(index, agent: agent))
    }

    private func helpText(_ index: Int, agent: HerdrAgent?) -> String {
        let action = bridge.keyBindings.action(for: index)
        switch action {
        case .none:
            return "Key \(index), no action"
        case .focusAgent:
            if let agent { return "\(agent.displayName) — \(agent.status)" }
            if Pad.agentSlot(for: index) != nil { return "Key \(index), no agent in this slot" }
            return "Key \(index), return focus to the currently selected Herdr agent"
        default:
            return "Key \(index), \(action.summary)"
        }
    }

    // MARK: - Agents

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bridge.agents.isEmpty {
                Text("No agents running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            } else {
                ForEach(Array(bridge.agents.prefix(Pad.agentKeyIDs.count).enumerated()), id: \.offset) { index, agent in
                    Button {
                        Task { await bridge.focusSlot(index) }
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(bridge.keyColors[Pad.agentKeyIDs[index]] ?? Color.secondary.opacity(0.3))
                                .frame(width: 9, height: 9)
                            Text("\(index)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(agent.shortName).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(agent.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Other states

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Monitoring is needed", systemImage: "lock.fill")
                .font(.callout).bold()
            Text("macOS blocks access to the pad until this app is allowed to monitor input.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Request Access") {
                    runtime.requestStudioInputMonitoringAccess()
                }
                Button("Show me how…") {
                    runtime.showInputMonitoringHelp()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var inspectorActiveHint: some View {
        Label(
            runtime.isTransitioning ? "Switching pad ownership…" : "Inspector has the pad",
            systemImage: runtime.isTransitioning ? "arrow.triangle.2.circlepath" : "waveform.path.ecg"
        )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var idleHint: some View {
        Text("Switch on to light each agent on its own key.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Open at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 14).padding(.top, 8)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Registering only works from a bundled, signed app;
                        // reflect reality rather than leaving the box ticked.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            Toggle("Emulate the pad", isOn: Binding(
                get: { bridge.emulator != nil },
                set: { on in
                    Task {
                        await runtime.setEmulation(on)
                        if let emulator = bridge.emulator {
                            EmulatorWindowController.shared.show(emulator)
                        } else {
                            EmulatorWindowController.shared.close()
                        }
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .padding(.horizontal, 14).padding(.top, 4)
            .help("Drive a virtual pad instead of the hardware")
            .disabled(runtime.isInspectorActive || runtime.isTransitioning)

            HStack {
                Menu {
                    Button("Welcome") { WelcomeWindowController.shared.show() }
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Welcome")
                .help("Open the Studio welcome screen")
                Button("Refresh") { Task { await bridge.forceRepaint() } }
                    .disabled(!bridge.isRunning)
                Button("Studio") {
                    StudioWindowController.shared.show(runtime: runtime)
                }
                .help("Open the Studio workspace and Inspector sidebar")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

#Preview("Menu Bar Panel") {
    let runtime = StudioRuntimeCoordinator.preview()
    return MenuPanelView()
        .environmentObject(runtime.bridge)
        .environmentObject(runtime)
        .frame(width: 340)
        .allowsHitTesting(false)
}

#Preview("Menu Bar · Permission Needed") {
    let bridge = BridgeController.previewFixture(permissionDenied: true)
    let runtime = StudioRuntimeCoordinator.preview(bridge: bridge)
    return MenuPanelView()
        .environmentObject(bridge)
        .environmentObject(runtime)
        .frame(width: 340)
        .allowsHitTesting(false)
}
