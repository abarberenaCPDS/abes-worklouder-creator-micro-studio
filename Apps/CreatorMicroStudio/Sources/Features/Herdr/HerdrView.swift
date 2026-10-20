import SwiftUI
import CreatorMicroStudioKit

/// The Studio's Herdr page: how the bridge reaches Herdr, which pad input
/// reaches which agent, the agents no input reaches, and every input whose
/// action goes through Herdr. Clicking an agent row focuses it.
struct HerdrView: View {
    @ObservedObject var bridge: BridgeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = bridge.lastActionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                connectionCard
                mappingCard
                if !unassigned.isEmpty { unassignedCard }
                boundInputsCard
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Herdr")
                    .font(.largeTitle.weight(.bold))
                Text("Where the bridge finds Herdr, and which input reaches which agent.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(bridge.herdr.reachability.title, systemImage: "circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(reachabilityColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var reachabilityColor: Color {
        switch bridge.herdr.reachability {
        case .connected: return .green
        case .unreachable: return .orange
        case .error: return .red
        case .unknown: return .secondary
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        let herdr = bridge.herdr
        return VStack(alignment: .leading, spacing: 12) {
            cardTitle("CONNECTION")
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(herdr.reachability.title)
                        .font(.headline)
                    Text(bridge.isRunning ? "Refreshes every \(formattedInterval(herdr.pollInterval))" : "The Studio bridge is off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let message = herdr.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(reachabilityColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Divider()
            LabeledContent("Socket") {
                Text(herdr.socketPath)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent("Source", value: herdr.socketSource.title)
            LabeledContent("Version", value: versionText)
            LabeledContent("Last refresh") {
                if let date = herdr.lastRefreshAt {
                    Text("\(Text(date, style: .relative)) ago")
                } else {
                    Text("Never")
                }
            }
            if let attempt = herdr.lastFailedAttemptAt {
                LabeledContent("Last attempt") {
                    Text("\(Text(attempt, style: .relative)) ago")
                }
            }
            LabeledContent("Event stream") {
                Text(eventStreamText)
                    .foregroundStyle(herdr.lifecycleSubscribed ? Color.primary : Color.orange)
            }
            LabeledContent("Workspaces", value: "\(herdr.workspaces.count) · \(herdr.tabs.count) tabs")
            if herdr.socketSource != .environment {
                Text("Set HERDR_SOCKET_PATH in the Studio's environment to use a different socket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var versionText: String {
        switch (bridge.herdr.version, bridge.herdr.protocolVersion) {
        case let (version?, proto?): return "\(version) · protocol \(proto)"
        case let (version?, nil): return version
        case let (nil, proto?): return "Protocol \(proto)"
        default: return "—"
        }
    }

    private var eventStreamText: String {
        let herdr = bridge.herdr
        let streams = herdr.statusStreamCount == 1 ? "1 status stream" : "\(herdr.statusStreamCount) status streams"
        return herdr.lifecycleSubscribed ? "Subscribed · \(streams)" : "Not subscribed · polling only"
    }

    private func formattedInterval(_ interval: TimeInterval) -> String {
        interval.rounded() == interval ? "\(Int(interval)) s" : String(format: "%.1f s", interval)
    }

    // MARK: - Mapping

    /// Inputs that reach a slot: agent keys on Focus agent and any input on
    /// Focus agent slot N.
    private var slotMappings: [HerdrInputMapping] {
        bridge.inputMappings.filter { $0.slot != nil }
    }

    private var unassigned: [Int] { bridge.unassignedAgentIndices }

    private var mappingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                cardTitle("AGENT KEYS")
                Spacer()
                Text("\(bridge.agents.count) agents")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if slotMappings.isEmpty {
                emptyText("No input focuses an agent slot.")
            } else {
                mappingHeader
                Divider()
                ForEach(Array(slotMappings.enumerated()), id: \.element.id) { index, mapping in
                    mappingRow(mapping)
                    if index < slotMappings.count - 1 { Divider() }
                }
            }
            Text("Click a row to focus that agent in Herdr.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Dedicated Focus Agent keys follow the configured physical reading-order layout. Custom actions take precedence; explicit Focus Agent Slot actions can reach agents beyond that layout.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var mappingHeader: some View {
        HStack(spacing: 12) {
            Text("Input").frame(width: Column.input, alignment: .leading)
            Text("Slot").frame(width: Column.slot, alignment: .leading)
            Text("Agent").frame(maxWidth: .infinity, alignment: .leading)
            Text("Workspace › tab").frame(width: Column.location, alignment: .leading)
            Text("Pane").frame(width: Column.pane, alignment: .leading)
            Color.clear.frame(width: Column.chevron)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func mappingRow(_ mapping: HerdrInputMapping) -> some View {
        Button {
            if let agent = mapping.agent { Task { await bridge.focusAgent(agent) } }
        } label: {
            HStack(spacing: 12) {
                Label(mapping.input.name, systemImage: mapping.input.symbol)
                    .lineLimit(1)
                    .frame(width: Column.input, alignment: .leading)
                Text(mapping.slot.map { "\($0 + 1)" } ?? "—")
                    .font(.body.monospacedDigit())
                    .frame(width: Column.slot, alignment: .leading)
                if let agent = mapping.agent {
                    agentCell(agent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(bridge.herdr.location(of: agent) ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: Column.location, alignment: .leading)
                    Text(agent.paneID ?? agent.terminalID ?? "—")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: Column.pane, alignment: .leading)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: Column.chevron)
                } else {
                    Text("Empty slot")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(width: Column.location + Column.pane + Column.chevron + 24, height: 1)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(mapping.agent == nil || !bridge.herdr.isConnected)
        .help(mapping.agent.map { "Focus \($0.displayName)" } ?? "No agent in this slot")
        .accessibilityLabel(accessibilityLabel(for: mapping))
    }

    private func accessibilityLabel(for mapping: HerdrInputMapping) -> String {
        guard let slot = mapping.slot else { return mapping.input.name }
        guard let agent = mapping.agent else { return "\(mapping.input.name), slot \(slot + 1), empty" }
        return "\(mapping.input.name), slot \(slot + 1), \(agent.displayName), \(agent.status)"
    }

    /// Status dot, name, harness, focus marker and working directory.
    private func agentCell(_ agent: HerdrAgent) -> some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor(agent.status))
                .frame(width: 10, height: 10)
                .help(agent.status.capitalized)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .lineLimit(1)
                    Text(agent.harnessName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if agent.focused {
                        Text("Focused")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
                Text(agentDetail(agent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func agentDetail(_ agent: HerdrAgent) -> String {
        let status = agent.status.capitalized
        guard let directory = agent.workingDirectory else { return status }
        return "\(status) · \((directory as NSString).abbreviatingWithTildeInPath)"
    }

    /// The colour the pad paints this status, from the lighting preferences.
    private func statusColor(_ status: String) -> Color {
        Color(packedRGB: bridge.lighting.look(forStatus: status).color)
    }

    // MARK: - Unassigned

    private var unassignedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                cardTitle("NOT ON THE PAD")
                Spacer()
                Text("\(unassigned.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("These agents have no dedicated or explicit slot input. Focus Agent on an action key still returns to whichever agent is currently selected in Herdr. Click a row here to focus it directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(unassigned.enumerated()), id: \.element) { index, agentIndex in
                if agentIndex < bridge.agents.count {
                    let agent = bridge.agents[agentIndex]
                    Button {
                        Task { await bridge.focusAgent(agent) }
                    } label: {
                        HStack(spacing: 12) {
                            Text("#\(agentIndex + 1)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: Column.slot, alignment: .leading)
                            agentCell(agent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(bridge.herdr.location(of: agent) ?? "—")
                                .lineLimit(1)
                                .frame(width: Column.location, alignment: .leading)
                            Text(agent.paneID ?? agent.terminalID ?? "—")
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .frame(width: Column.pane, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: Column.chevron)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!bridge.herdr.isConnected)
                    .help("Focus \(agent.displayName)")
                    if index < unassigned.count - 1 { Divider() }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Bound inputs

    /// Inputs whose action goes through Herdr,
    /// other than the plain slot keys shown above.
    private var herdrInputs: [HerdrInputMapping] {
        bridge.inputMappings.filter { mapping in
            guard mapping.action.kind.usesHerdr else { return false }
            if case .focusAgent = mapping.action, mapping.slot != nil { return false }
            return true
        }
    }

    private var focusedAgent: HerdrAgent? { bridge.agents.first(where: \.focused) }

    private var boundInputsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                cardTitle("INPUTS USING HERDR")
                Spacer()
                Text("\(herdrInputs.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if herdrInputs.isEmpty {
                emptyText("No other input is bound to a Herdr, prompt or tune action.")
            } else {
                ForEach(Array(herdrInputs.enumerated()), id: \.element.id) { index, mapping in
                    HStack(spacing: 12) {
                        Label(mapping.input.name, systemImage: mapping.input.symbol)
                            .lineLimit(1)
                            .frame(width: Column.input, alignment: .leading)
                        Label(mapping.action.summary, systemImage: mapping.action.symbol)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(target(for: mapping))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 220, alignment: .leading)
                    }
                    .padding(.vertical, 3)
                    .help(mapping.action.category.title)
                    if index < herdrInputs.count - 1 { Divider() }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Who an input's action lands on, in the same terms the bridge uses.
    private func target(for mapping: HerdrInputMapping) -> String {
        let focused = focusedAgent.map { "→ \($0.displayName)" } ?? "→ focused agent"
        switch mapping.action {
        case .focusAgent:
            return focusedAgent.map { "→ current agent (\($0.displayName))" } ?? "→ current agent"
        case .focusSlot:
            if let agent = mapping.agent { return "→ \(agent.displayName)" }
            return "→ empty slot"
        case .nextTab, .previousTab:
            return focusedWorkspace.map { "→ tabs in \($0.displayLabel)" } ?? "→ tabs"
        case .nextWorkspace, .previousWorkspace:
            return "→ \(bridge.herdr.workspaces.count) workspaces"
        case .focusPane, .zoomPane, .herdrCommand:
            return "→ focused pane"
        case .sendKeysToAgent, .insertText, .submitPrompt:
            return focused
        case .effortUp, .effortDown, .modelNext, .modelPrevious, .modelPickerConfirm, .modelPickerCancel:
            return focused + " · Tune"
        default:
            return "—"
        }
    }

    private var focusedWorkspace: HerdrWorkspace? {
        bridge.herdr.workspaces.first(where: \.focused)
            ?? focusedAgent.flatMap { bridge.herdr.workspace(id: $0.workspaceID) }
    }

    // MARK: - Pieces

    private enum Column {
        static let input: CGFloat = 130
        static let slot: CGFloat = 36
        static let location: CGFloat = 190
        static let pane: CGFloat = 80
        static let chevron: CGFloat = 16
    }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(1)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

#Preview("Herdr") {
    HerdrView(bridge: .previewFixture())
        .frame(width: 920, height: 820)
}

#Preview("Herdr · Not Checked") {
    HerdrView(bridge: .previewFixture(permissionDenied: true))
        .frame(width: 920, height: 720)
}
