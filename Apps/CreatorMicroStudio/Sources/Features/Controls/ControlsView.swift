import AppKit
import SwiftUI
import CreatorMicroStudioKit

/// The input mapping editor: a clickable pad on the left, every input in a
/// grouped list on the right, and an editor for whatever is selected. Edits
/// save straight to config.json — action edits save as made, typed text saves
/// on Return, blur or 3 s idle, and agent layout drafts require Apply.
///
/// The bridge publishes on every Herdr poll and status event, so this view's
/// body runs often. Everything heavy below it — the 20 list rows with their
/// action menus, the pad drawing, the editor — is an `Equatable` view built
/// from plain values, so a publish that changes nothing they show costs a
/// comparison, not a rebuild of ~500 menu items. Nothing here touches the
/// disk, a process or a socket while rendering.
struct ControlsView: View {
    @ObservedObject var bridge: BridgeController

    @State private var selection: Set<Int>
    @State private var selectionAnchor: Int?
    /// The single selected input's action as it is being edited. Text edits
    /// save on Return, on losing focus or after 3 s idle; everything else
    /// saves at once.
    @State private var editing: InputAction = .none
    @State private var editingID: Int?
    @State private var pendingSave: Task<Void, Never>?
    /// What "Apply to N selected" writes when several inputs are selected.
    @State private var bulkAction: InputAction = .none
    @State private var saveError: String?
    @State private var confirmingResetAll = false
    @State private var draftAgentKeys: [Int]
    @State private var loadedAgentKeys: [Int]
    @State private var pendingAgentKeys: [Int]?
    @State private var pendingAgentBindings: KeyBindings?
    @State private var confirmingAgentLayout = false
    @State private var confirmingAgentReset = false
    @State private var flashedInput: Int?

    /// The familiar factory layout, in physical reading order. This is a
    /// reset target, not a runtime slot lookup.
    private static let defaultAgentKeyIDs = Pad.agentKeyIDs

    init(bridge: BridgeController, initialSelection: Set<Int> = []) {
        self.bridge = bridge
        _selection = State(initialValue: initialSelection)
        _selectionAnchor = State(initialValue: initialSelection.sorted().first)
        _draftAgentKeys = State(initialValue: bridge.agentKeyIDs)
        _loadedAgentKeys = State(initialValue: bridge.agentKeyIDs)
    }

    /// How long a text parameter waits after the last keystroke to save.
    private static let textSaveDelay: UInt64 = 3_000_000_000

    /// List order, which is also the order ⇧-click ranges follow on the pad.
    private static let inputOrder = Pad.inputs.map(\.id)

    private static let leftColumnWidth: CGFloat = 440
    private static let listMinWidth: CGFloat = 460
    private static let stackedListHeight: CGFloat = 640

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            padCard
            agentLayoutCard
            editorCard
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            notices
            // Side by side when the window is wide enough; otherwise one
            // scrolling column. Either way the page never asks for more than
            // the window has: a layout larger than the window pushes the page
            // off its top edge, which reads as a blank, frozen window.
            GeometryReader { proxy in
                if proxy.size.width >= Self.leftColumnWidth + 18 + Self.listMinWidth {
                    HStack(alignment: .top, spacing: 18) {
                        ScrollView {
                            leftColumn.padding(.bottom, 4)
                        }
                        .frame(width: Self.leftColumnWidth)

                        inputList
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            leftColumn.frame(maxWidth: Self.leftColumnWidth)
                            inputList
                                .frame(height: Self.stackedListHeight)
                        }
                        .padding(.bottom, 4)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            bridge.refreshAccessibilityStatus()
            loadEditor()
        }
        .onDisappear { _ = commitPending() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            bridge.refreshAccessibilityStatus()
        }
        .onChange(of: selection) { newSelection in
            _ = commitPending()
            if newSelection.count == 1 { selectionAnchor = newSelection.first }
            loadEditor()
        }
        .onChange(of: editing) { newValue in editingChanged(newValue) }
        .onChange(of: bridge.keyBindings) { _ in
            // Follow reloads (an inline picker, the standalone Inspector, a
            // hand edit) unless a text edit is still waiting to be saved.
            guard pendingSave == nil, let editingID else { return }
            editing = bridge.action(for: editingID)
        }
        .onChange(of: bridge.agentKeyIDs) { keys in
            if orderedAgentKeys(draftAgentKeys) == orderedAgentKeys(loadedAgentKeys) {
                draftAgentKeys = orderedAgentKeys(keys)
            }
            loadedAgentKeys = keys
        }
        .onChange(of: bridge.lastAction) { event in flash(event?.input) }
        .confirmationDialog("Reset every input to its default action?",
                            isPresented: $confirmingResetAll) {
            Button("Reset all inputs", role: .destructive) {
                save { try bridge.resetActions(for: Pad.configurableInputIDs) }
            }
        } message: {
            Text("Actions return to their defaults, including Focus Agent on the configured agent keys. The device keymap is not touched.")
        }
        .confirmationDialog(agentLayoutConfirmationTitle,
                            isPresented: $confirmingAgentLayout) {
            Button("Apply agent layout") { applyPendingAgentLayout() }
            Button("Cancel", role: .cancel) { clearPendingAgentLayout() }
        } message: {
            Text(agentLayoutConfirmationMessage)
        }
        .confirmationDialog("Reset the agent layout?",
                            isPresented: $confirmingAgentReset) {
            Button("Reset agent layout", role: .destructive) {
                applyPendingAgentLayout()
            }
            Button("Cancel", role: .cancel) { clearPendingAgentLayout() }
        } message: {
            Text(resetAgentLayoutMessage)
        }
    }

    // MARK: - Header and notices

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Controls")
                    .font(.largeTitle.weight(.bold))
                Text("Choose what every key, the dial and the joystick do. Actions save as you edit; agent layouts require Apply.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            let customised = Pad.configurableInputIDs.filter { bridge.keyBindings.isCustomised($0) }.count
            if customised > 0 {
                Text("\(customised) customised")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Button("Reset all…") { confirmingResetAll = true }
                .buttonStyle(.bordered)
                .disabled(customised == 0)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if bridge.keymapNeedsRetry {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(bridge.deviceError ?? "The pad refused its Studio bindings.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                RetryKeymapButton(title: "Retry binding", busy: bridge.keymapBusy) {
                    Task { await bridge.retryKeymapBinding() }
                }
            }
        }
        if bridge.needsAccessibility {
            accessibilityNotice
        }
        if let saveError {
            noticeRow(saveError, symbol: "exclamationmark.triangle.fill", color: .red) {
                self.saveError = nil
            }
        }
        if let error = bridge.lastActionError {
            noticeRow(error, symbol: "exclamationmark.triangle.fill", color: .red) {
                bridge.clearActionError()
            }
        }
    }

    @ViewBuilder
    private var accessibilityNotice: some View {
        let ids = bridge.inputsRequiringAccessibility
        let names = ids.compactMap { Pad.input($0)?.name }.joined(separator: ", ")
        // Which inputs need it, and with what, so a default (the dial push's
        // play/pause) does not read as something the user set up.
        let details = ids.compactMap { id -> String? in
            guard let input = Pad.input(id) else { return nil }
            let action = bridge.keyBindings.action(for: id)
            let isDefault = !bridge.keyBindings.isCustomised(id)
            return "\(input.name): \(action.summary)\(isDefault ? " (default)" : "")"
        }.joined(separator: " · ")
        if bridge.accessibilityTrusted {
            Label("Accessibility allowed — system actions (\(names)) can post events.",
                  systemImage: "checkmark.shield.fill")
                .font(.callout)
                .foregroundStyle(.green)
        } else {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Accessibility needed")
                        .font(.headline)
                    Text("Only these inputs need it — \(details). They post scroll, shortcut, media, voice or typing events, which macOS only allows once the Studio is enabled under Privacy & Security → Accessibility (called “Device Control and Data Access” on newer macOS). Every other input works without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Request access") { bridge.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .help("Ask macOS for Accessibility (Device Control and Data Access)")
                Button("Show me how…") {
                    PermissionHelperWindowController.shared.show(.accessibility)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private func noticeRow(_ text: String, symbol: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(text, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
    }

    // MARK: - Pad

    private var padCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PAD")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Spacer()
                quickSelectMenu
            }
            ControlsPadView(
                keyBindings: bridge.keyBindings,
                keyColors: bridge.keyColors,
                agentNames: bridge.agents.map(\.displayName),
                agentKeyIDs: bridge.agentKeyIDs,
                selection: selection,
                flashedInput: flashedInput,
                onSelect: padClick
            )
            .equatable()
            Text("Click to select · ⌘-click to add or remove · ⇧-click for a range")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Agent layout

    private var agentLayoutIsDirty: Bool {
        orderedAgentKeys(draftAgentKeys) != orderedAgentKeys(bridge.agentKeyIDs)
    }

    private var orderedDraftAgentKeys: [Int] { orderedAgentKeys(draftAgentKeys) }

    private var agentLayoutCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("AGENT LAYOUT")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Spacer()
                Text("\(orderedDraftAgentKeys.count) agent keys · \(Pad.configurableActionKeyIDs.count - orderedDraftAgentKeys.count) action keys")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(Pad.displayRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in
                        agentLayoutKey(key)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Apply layout") { requestAgentLayout(orderedDraftAgentKeys) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!agentLayoutIsDirty)
                Button("Reset…") {
                    requestAgentLayoutReset()
                }
                    .buttonStyle(.bordered)
                    .disabled(!agentLayoutIsDirty && orderedAgentKeys(bridge.agentKeyIDs) == Self.defaultAgentKeyIDs)
                Spacer(minLength: 4)
            }
            Text("Slots follow Herdr's current agent list, not agent identities. Selected keys are draft slots until applied; a custom action on a layout key still runs instead of focusing its slot. No drag ordering — slots follow physical reading order.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func agentLayoutKey(_ key: Int) -> some View {
        let slot = orderedDraftAgentKeys.firstIndex(of: key)
        let currentActionTakesPrecedence = slot != nil && bridge.action(for: key) != .focusAgent
        return Button {
            if let slot = draftAgentKeys.firstIndex(of: key) {
                draftAgentKeys.remove(at: slot)
            } else {
                draftAgentKeys = orderedAgentKeys(draftAgentKeys + [key])
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(key)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                if let slot {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .black))
                    Text("S\(slot + 1)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 34, minHeight: 28)
            .padding(.horizontal, 3)
            .background(slot == nil ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(currentActionTakesPrecedence ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.2), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(slot.map { currentActionTakesPrecedence
            ? "Key \(key), draft slot \($0 + 1); its current action runs, not agent status."
            : "Key \(key), draft agent slot \($0 + 1)"
        } ?? "Key \(key), action key in the draft layout")
        .accessibilityLabel(slot.map { currentActionTakesPrecedence
            ? "Key \(key), draft slot \($0 + 1), current action takes precedence"
            : "Key \(key), draft agent slot \($0 + 1)"
        } ?? "Key \(key), action key")
        .accessibilityAddTraits(slot == nil ? [] : .isSelected)
        .accessibilityHint(slot == nil ? "Activate to add this key to the draft agent layout." : "Activate to remove this key from the draft agent layout.")
    }

    private func orderedAgentKeys(_ keys: [Int]) -> [Int] {
        let selected = Set(keys)
        return Pad.displayRows.flatMap { $0 }.filter { selected.contains($0) }
    }

    private func requestAgentLayout(_ keys: [Int]) {
        guard let replacedCustom = prepareAgentLayout(keys) else { return }
        if !replacedCustom.isEmpty {
            confirmingAgentLayout = true
        } else {
            applyPendingAgentLayout()
        }
    }

    private func requestAgentLayoutReset() {
        guard prepareAgentLayout(Self.defaultAgentKeyIDs) != nil else { return }
        confirmingAgentReset = true
    }

    /// Commit a waiting text action before deciding which actions an incoming
    /// layout would replace. Capture these exact bindings for the later
    /// compare-and-save so a concurrent writer cannot be silently overwritten.
    private func prepareAgentLayout(_ keys: [Int]) -> [Int]? {
        guard flushPendingActionSave() else { return nil }
        let ordered = orderedAgentKeys(keys)
        let added = Set(ordered).subtracting(bridge.agentKeyIDs)
        let replacedCustom = added.filter { bridge.keyBindings.isCustomised($0) }.sorted()
        pendingAgentKeys = ordered
        pendingAgentBindings = bridge.keyBindings
        return replacedCustom
    }

    private func clearPendingAgentLayout() {
        pendingAgentKeys = nil
        pendingAgentBindings = nil
    }

    private var resetAgentLayoutMessage: String {
        let bindings = pendingAgentBindings ?? bridge.keyBindings
        let added = Set(Self.defaultAgentKeyIDs).subtracting(bindings.agentKeyIDs)
        let replacedCustom = added.filter { bindings.isCustomised($0) }.sorted()
        let factory = "Restore the factory layout (keys 1, 0, 2, 3, 4 and 5 in physical reading order)."
        guard !replacedCustom.isEmpty else { return factory + " Removed keys keep their actions." }
        let details = replacedCustom.map { "Key \($0) (\(bindings.action(for: $0).summary))" }.joined(separator: ", ")
        return factory + " This replaces custom actions on newly added keys: \(details). Removed keys keep their actions."
    }

    private var agentLayoutConfirmationTitle: String {
        "Apply this agent layout?"
    }

    private var agentLayoutConfirmationMessage: String {
        guard let keys = pendingAgentKeys else { return "Apply the selected physical reading-order slots." }
        let bindings = pendingAgentBindings ?? bridge.keyBindings
        let added = Set(keys).subtracting(bindings.agentKeyIDs)
        let replacedCustom = added.filter { bindings.isCustomised($0) }.sorted()
        guard !replacedCustom.isEmpty else {
            return "New agent keys: \(added.sorted().map(String.init).joined(separator: ", ")). Their current actions will be replaced with Focus Agent."
        }
        let details = replacedCustom.map { key in
            "Key \(key) (\(bindings.action(for: key).summary))"
        }.joined(separator: ", ")
        return "Adding these keys replaces their custom actions with Focus Agent: \(details). Other removed keys keep their actions."
    }

    private func applyPendingAgentLayout() {
        guard let keys = pendingAgentKeys else { return }
        let expectedBindings = pendingAgentBindings
        pendingAgentKeys = nil
        pendingAgentBindings = nil
        guard flushPendingActionSave() else { return }
        guard let expectedBindings else {
            saveError = "Could not save the agent layout: no confirmed binding snapshot is available."
            return
        }
        do {
            try bridge.setAgentKeys(keys, expectedBindings: expectedBindings)
            saveError = nil
            draftAgentKeys = orderedAgentKeys(bridge.agentKeyIDs)
            loadEditor()
        } catch {
            if error as? KeyBindings.EditError == .configurationChanged {
                bridge.reloadKeyBindings()
                loadEditor()
            }
            saveError = "Could not save the agent layout (the configuration may have changed since confirmation): \(error.localizedDescription)"
        }
    }

    private var quickSelectMenu: some View {
        Menu {
            Button("All keys") { selection = Set(Pad.InputGroup.keys.inputs.map(\.id)) }
            Button("Agent keys (\(bridge.agentKeyIDs.count))") { selection = Set(bridge.agentKeyIDs) }
            Button("Dial") { selection = Set(Pad.InputGroup.dial.inputs.map(\.id)) }
            Button("Joystick") { selection = Set(Pad.InputGroup.joystick.inputs.map(\.id)) }
            Button("Customised inputs") {
                selection = Set(Pad.configurableInputIDs.filter { bridge.keyBindings.isCustomised($0) })
            }
            Divider()
            Button("Everything") { selection = Set(Pad.configurableInputIDs) }
            Button("Clear selection") { selection = [] }
                .disabled(selection.isEmpty)
        } label: {
            Label("Select", systemImage: "checklist")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func padClick(_ id: Int) {
        let flags = NSEvent.modifierFlags
        let order = Self.inputOrder
        if flags.contains(.shift),
           let anchor = selectionAnchor,
           let from = order.firstIndex(of: anchor),
           let to = order.firstIndex(of: id) {
            let range = Set(order[min(from, to)...max(from, to)])
            selection = flags.contains(.command) ? selection.union(range) : range
        } else if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            selectionAnchor = id
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    private func flash(_ input: Int?) {
        guard let input else { return }
        flashedInput = input
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            if flashedInput == input { flashedInput = nil }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch selectedIDs.count {
            case 0: emptyEditor
            case 1: singleEditor(selectedIDs[0])
            default: bulkEditor(selectedIDs)
            }
            lastActionFooter
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var selectedIDs: [Int] {
        Self.inputOrder.filter { selection.contains($0) }
    }

    private var emptyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nothing selected", systemImage: "hand.tap")
                .font(.headline)
            Text("Select an input on the pad or in the list to edit its action. Select several to give them all the same action or reset them together.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func singleEditor(_ id: Int) -> some View {
        let input = Pad.input(id)
        let customised = bridge.keyBindings.isCustomised(id)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: input?.symbol ?? "square")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(input?.name ?? "Input \(id)")
                        .font(.title3.weight(.semibold))
                    if let line = herdrLine(for: id, action: editing) {
                        HerdrMappingLabel(line: line)
                    }
                }
                Spacer()
                Text(customised ? "Customised" : "Default")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(customised ? Color.accentColor : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((customised ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())
            }

            if id == Pad.dialPushID, !bridge.dialPushAvailable {
                DialPushUnavailableNote(
                    message: dialPushUnavailableMessage,
                    busy: bridge.keymapBusy,
                    retry: retryDialPush
                )
            }

            ActionEditor(action: $editing, inputID: id, context: editorContext, onSubmit: { _ = commitPending() })
                .equatable()
                .id(id)

            HStack {
                Button {
                    // Run what the editor shows, even if saving it failed.
                    _ = commitPending()
                    bridge.perform(editing, from: id)
                } label: {
                    Label("Test", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help("Run the action shown here now, as if this input were pressed (⌘↩)")
                Spacer()
                Button("Reset to default") {
                    pendingSave?.cancel()
                    pendingSave = nil
                    save { try bridge.resetActions(for: [id]) }
                    editing = bridge.action(for: id)
                }
                .disabled(!customised && editing == InputAction.defaultAction(for: id))
                .help("Default: \(InputAction.defaultAction(for: id).summary)")
            }
        }
    }

    private func bulkEditor(_ ids: [Int]) -> some View {
        let names = ids.compactMap { Pad.input($0)?.shortName }.joined(separator: ", ")
        let customisedCount = ids.filter { bridge.keyBindings.isCustomised($0) }.count
        let allSame = Set(ids.map { bridge.action(for: $0) }).count == 1
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(ids.count) inputs selected")
                    .font(.title3.weight(.semibold))
                Text(names)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !allSame {
                    Text("They currently have different actions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ActionEditor(action: $bulkAction, inputID: nil, context: editorContext, onSubmit: {})
                .equatable()

            HStack {
                Button {
                    let action = bulkAction
                    save { try bridge.setAction(action, for: ids) }
                } label: {
                    Label("Set action for \(ids.count) selected", systemImage: "square.stack.3d.down.right")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Reset \(ids.count) to default") {
                    save { try bridge.resetActions(for: ids) }
                }
                .disabled(customisedCount == 0)
            }
            Text("Test needs a single selection.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lastActionFooter: some View {
        if let event = bridge.lastAction {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(bridge.lastActionError == nil ? Color.accentColor : .red)
                Text("Last ran \(event.action.summary)\(event.input.flatMap { Pad.input($0)?.name }.map { " from \($0)" } ?? "") at \(event.date.formatted(date: .omitted, time: .standard))")
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// What the editor shows from the bridge, as values.
    private var editorContext: ActionEditor.Context {
        ActionEditor.Context(
            agentNames: bridge.agents.map(\.displayName),
            agentKeyIDs: bridge.agentKeyIDs,
            accessibilityTrusted: bridge.accessibilityTrusted,
            herdr: HerdrCommand.Context(status: bridge.herdr, agents: bridge.agents)
        )
    }

    /// "Dial push isn't available on firmware 1.2 – the pad keeps play/pause".
    private var dialPushRowMessage: String {
        let firmware = bridge.firmware == "—" ? "this firmware" : "firmware \(bridge.firmware)"
        let keeps: String
        switch bridge.dialPushFirmwareCode {
        case nil, "KC_MPLY": keeps = "play/pause"
        case let code?: keeps = code
        }
        return "Dial push isn't available on \(firmware) – the pad keeps \(keeps)"
    }

    private var dialPushUnavailableMessage: String {
        dialPushRowMessage + ", so the action set here doesn't run."
    }

    private func retryDialPush() {
        Task { await bridge.retryKeymapBinding() }
    }

    // MARK: - Editing and saving

    private func loadEditor() {
        let ids = selectedIDs
        if ids.count == 1 {
            editingID = ids[0]
            editing = bridge.action(for: ids[0])
        } else {
            editingID = nil
            if let first = ids.first { bulkAction = bridge.action(for: first) }
        }
    }

    private func editingChanged(_ newValue: InputAction) {
        guard let id = editingID else { return }
        let saved = bridge.action(for: id)
        guard newValue != saved else {
            pendingSave?.cancel()
            pendingSave = nil
            return
        }
        pendingSave?.cancel()
        pendingSave = nil
        // Typing saves on Return, when the field loses focus, or after 3 s
        // without a keystroke — not on every keystroke, which would rewrite
        // config.json and repaint the pad. Kind and picker changes save now.
        if newValue.kind == saved.kind, newValue.kind.parameters.contains(where: \.isString) {
            pendingSave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.textSaveDelay)
                guard !Task.isCancelled else { return }
                _ = commitPending()
            }
        } else {
            _ = commitPending()
        }
    }

    /// Saves the single-input edit now if it differs from what is on disk.
    @discardableResult
    private func commitPending() -> Bool {
        pendingSave?.cancel()
        pendingSave = nil
        guard let id = editingID else { return true }
        let action = editing
        guard action != bridge.action(for: id) else { return true }
        return save { try bridge.setAction(action, for: id) }
    }

    /// Flushes the debounced text editor and reports failure to layout changes
    /// so a later layout write cannot mask an action-save failure.
    private func flushPendingActionSave() -> Bool {
        guard commitPending() else {
            saveError = (saveError ?? "Could not save the pending action.") + " The agent layout was not applied."
            return false
        }
        return true
    }

    /// Inline list picker: switch the kind and keep what parameters carry over.
    private func setKind(_ kind: InputAction.Kind, for id: Int) {
        if id == editingID {
            editing = editing.converted(to: kind)
        } else {
            let action = bridge.action(for: id).converted(to: kind)
            save { try bridge.setAction(action, for: id) }
        }
    }

    private func resetSelection() {
        let ids = selectedIDs
        guard !ids.isEmpty else { return }
        pendingSave?.cancel()
        pendingSave = nil
        save { try bridge.resetActions(for: ids) }
        loadEditor()
    }

    @discardableResult
    private func save(_ write: () throws -> Void) -> Bool {
        do {
            try write()
            saveError = nil
            return true
        } catch {
            saveError = "Could not save to config.json: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Input list

    private var inputList: some View {
        let mappings = Dictionary(bridge.inputMappings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(Pad.InputGroup.allCases) { group in
                    Section {
                        ForEach(group.inputs) { input in
                            inputRow(input, mapping: mappings[input.id])
                                .equatable()
                                .tag(input.id)
                        }
                    } header: {
                        Label(group.title, systemImage: group.symbol)
                    } footer: {
                        groupFooter(group)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onDeleteCommand(perform: resetSelection)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            }

            HStack {
                Text(selection.isEmpty
                     ? "⌘A selects everything · Delete resets the selection to its defaults"
                     : "\(selection.count) selected · Delete resets \(selection.count == 1 ? "it" : "them") to default")
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("Saved to \(abbreviatedConfigPath) · never written to the device")
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func groupFooter(_ group: Pad.InputGroup) -> some View {
        switch group {
        case .keys:
            Text("With Focus Agent, configured agent keys focus their slot in physical reading order; other keys return to the current agent. Custom actions take precedence over agent status.")
        case .dial:
            Text("Turning sends one event per detent; the push is the dial's click.")
        case .joystick:
            if bridge.absentJoystickInputs.isEmpty {
                Text("Four directions. Diagonals and the centre press have no firmware slot.")
            } else {
                Text("This pad profile's joystick has \(4 - bridge.absentJoystickInputs.count) of 4 directions; the missing ones never report. Diagonals and the centre press have no firmware slot.")
            }
        }
    }

    private func inputRow(_ input: Pad.Input, mapping: HerdrInputMapping?) -> InputRowView {
        let action = input.id == editingID ? editing : bridge.action(for: input.id)
        let id = input.id
        return InputRowView(
            input: input,
            action: action,
            customised: bridge.keyBindings.isCustomised(id),
            keyColor: bridge.keyColors[id],
            accessibilityTrusted: bridge.accessibilityTrusted,
            mappingLine: herdrLine(for: id, action: action, mapping: mapping),
            dialPushNote: id == Pad.dialPushID && !bridge.dialPushAvailable ? dialPushRowMessage : nil,
            absentNote: bridge.absentJoystickInputs.contains(id) ? absentJoystickMessage : nil,
            retryBusy: bridge.keymapBusy,
            copyCount: selection.count > 1 && selection.contains(id) ? selection.count : 0,
            onSetKind: { setKind($0, for: id) },
            onTest: {
                if id == editingID {
                    commitPending()
                    bridge.perform(editing, from: id)
                } else {
                    bridge.fire(id)
                }
            },
            onReset: {
                if id == editingID {
                    pendingSave?.cancel()
                    pendingSave = nil
                }
                save { try bridge.resetActions(for: [id]) }
                if id == editingID { editing = bridge.action(for: id) }
            },
            onCopyToSelection: {
                let ids = selectedIDs
                save { try bridge.setAction(action, for: ids) }
            },
            onRetryDialPush: retryDialPush
        )
    }

    private var absentJoystickMessage: String {
        "Not on this pad profile — its joystick has no sector for this direction"
    }

    private var abbreviatedConfigPath: String {
        (bridge.store.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Herdr mapping

    private func herdrLine(for id: Int, action: InputAction, mapping: HerdrInputMapping? = nil) -> HerdrMappingLine? {
        let mapping = mapping ?? bridge.inputMappings.first { $0.id == id }
        let slot: Int?
        switch action {
        case .focusAgent: slot = bridge.agentSlot(for: id)
        case .focusSlot(let selectedSlot): slot = selectedSlot - 1
        default: slot = nil
        }
        if let slot {
            // The live mapping only describes the saved action; an unsaved
            // slot change looks the agent up directly.
            let agent = mapping?.slot == slot ? mapping?.agent : (slot < bridge.agents.count ? bridge.agents[slot] : nil)
            if let agent {
                return HerdrMappingLine(
                    text: "Slot \(slot + 1) → \(agent.displayName) · \(agent.harnessName)",
                    color: agentStatusColor(agent.status)
                )
            }
            return HerdrMappingLine(text: "Slot \(slot + 1) · no agent", color: nil)
        }
        if action == .focusAgent {
            return HerdrMappingLine(text: "Current Herdr agent", color: nil)
        }
        return nil
    }
}

// MARK: - Shared pieces

private struct HerdrMappingLine: Equatable {
    var text: String
    var color: Color?
}

private struct HerdrMappingLabel: View {
    let line: HerdrMappingLine

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(line.color ?? Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(line.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private func agentStatusColor(_ status: String) -> Color {
    switch status {
    case "blocked": return .red
    case "working": return .orange
    case "done": return .blue
    case "idle": return .green
    default: return .secondary
    }
}

/// Every action kind, grouped by category, for menu pickers tagged by kind.
/// `withSymbols` adds each kind's SF Symbol; the 20 list-row menus leave
/// them out, which halves what each one costs to build.
@ViewBuilder
private func actionKindItems(withSymbols: Bool) -> some View {
    ForEach(InputAction.Category.allCases) { category in
        Section(category.title) {
            ForEach(category.kinds) { kind in
                if withSymbols {
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                } else {
                    Text(kind.title).tag(kind)
                }
            }
        }
    }
}

/// One row of the input list, from values only. Equatable on everything it
/// shows (closures excluded), so a bridge publish that does not change the
/// row skips its body — and its menu of every action kind.
private struct InputRowView: View, Equatable {
    let input: Pad.Input
    let action: InputAction
    let customised: Bool
    let keyColor: Color?
    let accessibilityTrusted: Bool
    let mappingLine: HerdrMappingLine?
    /// Set on the dial push row when the pad keeps its own code there.
    let dialPushNote: String?
    /// Set when the pad's profile has no sector for this joystick direction.
    let absentNote: String?
    let retryBusy: Bool
    /// The selection size when this row is part of a multi-selection.
    let copyCount: Int
    let onSetKind: (InputAction.Kind) -> Void
    let onTest: () -> Void
    let onReset: () -> Void
    let onCopyToSelection: () -> Void
    let onRetryDialPush: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.action == rhs.action && lhs.customised == rhs.customised
            && lhs.keyColor == rhs.keyColor && lhs.accessibilityTrusted == rhs.accessibilityTrusted
            && lhs.mappingLine == rhs.mappingLine && lhs.dialPushNote == rhs.dialPushNote
            && lhs.absentNote == rhs.absentNote
            && lhs.retryBusy == rhs.retryBusy && lhs.copyCount == rhs.copyCount
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(keyColor ?? Color.secondary.opacity(0.12))
                Text(input.group == .keys ? input.shortName : "")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(keyColor == nil ? Color.secondary : Color.black.opacity(0.7))
                if input.group != .keys {
                    Image(systemName: input.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(input.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                    if customised {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .help("Customised")
                    }
                    if action.requiresAccessibility, dialPushNote == nil {
                        Image(systemName: accessibilityTrusted ? "checkmark.shield" : "exclamationmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(accessibilityTrusted ? Color.secondary : Color.orange)
                            .help(accessibilityTrusted ? "Uses the Accessibility permission (allowed)"
                                                       : "Needs the Accessibility permission")
                            .accessibilityLabel(accessibilityTrusted ? "Uses Accessibility" : "Needs Accessibility")
                    }
                }
                if let dialPushNote {
                    HStack(spacing: 6) {
                        Label(dialPushNote, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        RetryKeymapButton(title: "Retry", busy: retryBusy, action: onRetryDialPush)
                            .controlSize(.small)
                            .help("Retry dial push binding: ask the pad to bind its push to KV_OAI_AG19 again")
                    }
                } else if let absentNote {
                    Label(absentNote, systemImage: "slash.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let mappingLine {
                    HerdrMappingLabel(line: mappingLine)
                } else if action.kind.isParameterised {
                    Text(action.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            Picker("Action", selection: Binding(get: { action.kind }, set: { onSetKind($0) })) {
                actionKindItems(withSymbols: false)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 150, idealWidth: 210, maxWidth: 210)
        }
        .padding(.vertical, 3)
        .help("\(input.name): \(action.summary)")
        .contextMenu {
            Button("Test", action: onTest)
            Button("Reset to default", action: onReset)
                .disabled(!customised)
            if copyCount > 1 {
                Divider()
                Button("Copy this action to all \(copyCount) selected", action: onCopyToSelection)
            }
            if dialPushNote != nil {
                Divider()
                Button("Retry dial push binding", action: onRetryDialPush)
                    .disabled(retryBusy)
            }
        }
    }
}

/// "Retry …" with a spinner while the keymap check runs.
private struct RetryKeymapButton: View {
    let title: String
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.mini) }
                Text(title)
            }
        }
        .disabled(busy)
    }
}

/// Above the dial push's editor when the pad will not report the press.
private struct DialPushUnavailableNote: View {
    let message: String
    let busy: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("The Studio asked the pad to report its push as KV_OAI_AG19, and it kept its own code instead. Nothing is wrong with the rest of the pad. Retrying rewrites the pad's keymap once more (a flash write).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RetryKeymapButton(title: "Retry dial push binding", busy: busy, action: retry)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Edits one action: its kind and whichever parameters that kind carries.
/// It writes straight into the binding; the owner decides when to save.
/// Built from values rather than the bridge, and Equatable on them, so a
/// Herdr poll does not rebuild it.
private struct ActionEditor: View, Equatable {
    /// What the editor reads from the bridge.
    struct Context: Equatable {
        var agentNames: [String]
        var agentKeyIDs: [Int]
        var accessibilityTrusted: Bool
        var herdr: HerdrCommand.Context
    }

    @Binding var action: InputAction
    /// The input being edited, for input-specific notes; nil in bulk mode.
    let inputID: Int?
    let context: Context
    let onSubmit: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.action == rhs.action && lhs.inputID == rhs.inputID && lhs.context == rhs.context
    }

    /// Which text parameter has keyboard focus; losing it saves.
    @FocusState private var focused: InputAction.Parameter?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Action")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Picker("Action", selection: Binding(
                        get: { action.kind },
                        set: { action = action.converted(to: $0) }
                    )) {
                        actionKindItems(withSymbols: true)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                ForEach(action.kind.parameters.filter { $0 != .text }) { parameter in
                    GridRow {
                        Text(parameter.label)
                            .foregroundStyle(.secondary)
                        parameterEditor(parameter)
                    }
                }
            }

            if action.kind.parameters.contains(.text) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(InputAction.Parameter.text.label)
                        .foregroundStyle(.secondary)
                    TextEditor(text: stringBinding)
                        .font(.body)
                        .focused($focused, equals: .text)
                        .frame(minHeight: 80, maxHeight: 140)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                }
            }

            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if action.kind == .herdrCommand {
                HerdrCommandHelp(command: action.stringValue ?? "", context: context.herdr)
            }
            if action.requiresAccessibility {
                if context.accessibilityTrusted {
                    Label("Uses the Accessibility permission (allowed).", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Needs the Accessibility permission for the Studio.", systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: focused) { [focused] _ in
            // Blur (or moving to another field) saves what was typed.
            if focused != nil { onSubmit() }
        }
    }

    private var stringBinding: Binding<String> {
        Binding(get: { action.stringValue ?? "" }, set: { action.stringValue = $0 })
    }

    @ViewBuilder
    private func parameterEditor(_ parameter: InputAction.Parameter) -> some View {
        switch parameter {
        case .slot:
            Picker("Slot", selection: Binding(get: { action.slot ?? 1 }, set: { action.slot = $0 })) {
                ForEach(InputAction.slotRange, id: \.self) { slot in
                    Text(slotTitle(slot)).tag(slot)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .direction:
            Picker("Direction", selection: Binding(
                get: { action.direction ?? .down }, set: { action.direction = $0 })) {
                ForEach(InputAction.Direction.allCases) { direction in
                    Image(systemName: direction.symbol)
                        .help(direction.title)
                        .tag(direction)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
        case .amount:
            Stepper(value: Binding(get: { action.amount ?? InputAction.defaultScrollAmount },
                                   set: { action.amount = $0 }),
                    in: InputAction.scrollAmountRange) {
                Text("\(action.amount ?? InputAction.defaultScrollAmount) lines")
                    .monospacedDigit()
            }
        case .mediaKey:
            Picker("Media key", selection: Binding(
                get: { action.mediaKey ?? .playPause }, set: { action.mediaKey = $0 })) {
                ForEach(InputAction.MediaKey.allCases) { key in
                    Label(key.title, systemImage: key.symbol).tag(key)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .text:
            EmptyView()
        case .keys, .herdrCommand, .shortcut, .url, .command:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField(parameter.label, text: stringBinding, prompt: Text(parameter.placeholder))
                        .textFieldStyle(.roundedBorder)
                        .font(parameter.isMonospaced ? .system(.body, design: .monospaced) : .body)
                        .labelsHidden()
                        .focused($focused, equals: parameter)
                        .onSubmit(onSubmit)
                    if parameter == .herdrCommand {
                        herdrExamplesMenu
                    }
                }
                if let hint = hint(for: parameter) {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Fills the field with a ready-made command; each was checked against
    /// Herdr's own usage text.
    private var herdrExamplesMenu: some View {
        Menu {
            ForEach(HerdrCommand.examples) { example in
                Button {
                    action.stringValue = example.command
                    onSubmit()
                } label: {
                    Text("\(example.title) — \(example.command)")
                }
            }
        } label: {
            Text("Examples")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fill in a ready-made Herdr command")
    }

    private func slotTitle(_ slot: Int) -> String {
        let index = slot - 1
        guard index < context.agentNames.count else { return "Slot \(slot) · empty" }
        return "Slot \(slot) · \(context.agentNames[index])"
    }

    private func hint(for parameter: InputAction.Parameter) -> String? {
        switch parameter {
        case .keys: return "Sent to the focused agent's pane. Space-separated key names: ctrl+c, esc, enter, up, tab…"
        case .shortcut: return "Modifiers cmd, shift, alt, ctrl, fn plus a key: a–z, 0–9, f1–f20, return, tab, space, esc, arrows, pageup…"
        case .herdrCommand: return "A Herdr CLI command without “herdr”, run directly (no shell). Quote arguments with spaces; each placeholder becomes one argument."
        case .url: return "A URL, a file or folder path, an app name or a bundle id."
        case .command: return "Runs in the background with /bin/zsh -lc. Failures and non-zero exits show up here."
        default: return nil
        }
    }

    private var note: String? {
        switch action {
        case .focusAgent:
            guard let inputID else { return "Configured agent keys focus their slots; every other input returns to the current agent." }
            if let slot = context.agentKeyIDs.firstIndex(of: inputID) {
                return "Focuses Herdr agent slot \(slot + 1)."
            }
            return "Returns focus to the agent already selected in Herdr. Configured agent keys focus their own slots."
        case .insertText:
            return "Types the text into the focused agent's pane without submitting it."
        case .submitPrompt:
            return "Pastes the text into the focused agent and presses Enter. Blocked agents are skipped."
        case .typeText:
            return "Types the text into whatever app has keyboard focus."
        case .voice:
            return "Taps the right Command key to start or stop dictation (Superwhisper)."
        case .mediaKey where inputID == Pad.dialPushID && action == InputAction.defaultAction(for: Pad.dialPushID):
            return "The default. The Studio sends play/pause as a media key event, so it needs the Accessibility permission, and it only works while the Studio bridge is on. Choose None or another action if you would rather not grant it."
        case .mediaKey, .scroll, .keyboardShortcut:
            return "Posted as a system event, so the Studio needs the Accessibility permission."
        default:
            return nil
        }
    }
}

/// Under a Herdr command field: the problem with what is typed, or what a
/// press would run right now, plus the placeholders.
private struct HerdrCommandHelp: View {
    let command: String
    /// Herdr's focus as of the last poll. Preview and validation are pure
    /// string work on this; nothing runs `herdr` or opens the socket.
    let context: HerdrCommand.Context
    @State private var showsPlaceholders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Runs:")
                        .foregroundStyle(.secondary)
                    Text(preview)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help("With Herdr's focus as of the last refresh. A press reads the current tab, workspace and pane fresh.")
            }
            DisclosureGroup("Placeholders", isExpanded: $showsPlaceholders) {
                Text(HerdrCommand.placeholderHelp)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
        .font(.caption)
    }

    private var problem: String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let legacy = HerdrCommand.legacyProblem(trimmed) { return legacy.localizedDescription }
        return HerdrCommand.validate(trimmed)
    }

    private var preview: String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "herdr …  (choose one from Examples)" }
        return HerdrCommand.preview(trimmed, context: context)
    }
}

// MARK: - Pad drawing

/// The physical layout with every input selectable: keycaps, the dial's
/// left / right halves and its push, and the joystick's four sectors.
private struct ControlsPadView: View, Equatable {
    let keyBindings: KeyBindings
    let keyColors: [Int: Color]
    /// Agent display names in slot order.
    let agentNames: [String]
    let agentKeyIDs: [Int]
    let selection: Set<Int>
    let flashedInput: Int?
    let onSelect: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyBindings == rhs.keyBindings && lhs.keyColors == rhs.keyColors
            && lhs.agentNames == rhs.agentNames && lhs.agentKeyIDs == rhs.agentKeyIDs
            && lhs.selection == rhs.selection
            && lhs.flashedInput == rhs.flashedInput
    }

    private let keyWidth: CGFloat = 88
    private let keyHeight: CGFloat = 76
    private let gap: CGFloat = 8

    var body: some View {
        VStack(spacing: gap) {
            ForEach(Array(Pad.physicalDisplayRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(row) { cell in cellView(cell) }
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Creator Micro 2 controls")
    }

    @ViewBuilder
    private func cellView(_ cell: Pad.DisplayCell) -> some View {
        switch cell {
        case .key(let key): keyCell(key)
        case .dial: dial
        case .joystick: joystick
        case .caseMark:
            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 28, height: 28)
                .frame(width: keyWidth, height: keyHeight)
                .accessibilityLabel("Case mark, not a key")
        }
    }

    private func keyCell(_ key: Int) -> some View {
        let action = keyBindings.action(for: key)
        let selected = selection.contains(key)
        let lit = keyColors[key]
        return Button { onSelect(key) } label: {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.32) : Color.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.14),
                                      lineWidth: selected ? 2.5 : 1)
                }
                .overlay {
                    if flashedInput == key {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.35))
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if let lit {
                            Circle().fill(lit).frame(width: 8, height: 8)
                        }
                        Image(systemName: action.symbol)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    if keyBindings.isCustomised(key) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(8)
                    }
                }
                .overlay(alignment: .leading) {
                    Text(keyTitle(key, action: action))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 7)
                        .padding(.top, 8)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(key)")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(6)
                }
                .frame(width: keyWidth, height: keyHeight)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(description(key, action: action))
        .accessibilityLabel(description(key, action: action))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func keyTitle(_ key: Int, action: InputAction) -> String {
        if action == .focusAgent {
            guard let slot = agentKeyIDs.firstIndex(of: key) else { return "Current agent" }
            return slot < agentNames.count ? agentNames[slot] : "Slot \(slot + 1)"
        }
        return action.title
    }

    private func description(_ input: Int, action: InputAction) -> String {
        let name = Pad.input(input)?.name ?? "Input \(input)"
        if action == .focusAgent, let slot = agentKeyIDs.firstIndex(of: input) {
            let agent = slot < agentNames.count ? ": \(agentNames[slot])" : ""
            return "\(name), Focus Agent slot \(slot + 1)\(agent); its color shows agent status."
        }
        if let slot = agentKeyIDs.firstIndex(of: input) {
            return "\(name), layout slot \(slot + 1), but \(action.summary) takes precedence; its color shows the action, not agent status."
        }
        return "\(name): \(action.summary); its color shows the action."
    }

    private var dial: some View {
        let diameter: CGFloat = 72
        let inner: CGFloat = 0.46
        return ZStack {
            segment(Pad.dialDownID, RingSector(start: .degrees(92), end: .degrees(268), innerRatio: inner))
            segment(Pad.dialUpID, RingSector(start: .degrees(-88), end: .degrees(88), innerRatio: inner))
            segment(Pad.dialPushID, RingSector(start: .degrees(0), end: .degrees(360), innerRatio: 0),
                    diameter: diameter * inner - 5)
        }
        .frame(width: diameter, height: diameter)
        .frame(width: keyWidth, height: keyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rotary dial")
    }

    private var joystick: some View {
        let diameter: CGFloat = 72
        let inner: CGFloat = 0.34
        return ZStack {
            segment(Pad.joyNorthID, RingSector(start: .degrees(-133), end: .degrees(-47), innerRatio: inner))
            segment(Pad.joyEastID, RingSector(start: .degrees(-43), end: .degrees(43), innerRatio: inner))
            segment(Pad.joySouthID, RingSector(start: .degrees(47), end: .degrees(133), innerRatio: inner))
            segment(Pad.joyWestID, RingSector(start: .degrees(137), end: .degrees(223), innerRatio: inner))
            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: diameter * inner - 8, height: diameter * inner - 8)
                .help("The joystick's centre press is not supported")
        }
        .frame(width: diameter, height: diameter)
        .frame(width: keyWidth, height: keyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Four-way joystick")
    }

    /// One selectable sector. Hit testing follows the sector's shape so the
    /// overlapping frames in the ZStack each answer only for their own area.
    private func segment(_ id: Int, _ sector: RingSector, diameter: CGFloat? = nil) -> some View {
        let input = Pad.input(id)
        let action = keyBindings.action(for: id)
        let selected = selection.contains(id)
        let offset = sector.labelOffset(diameter: diameter ?? 72)
        return Button { onSelect(id) } label: {
            ZStack {
                sector.fill(selected ? Color.accentColor.opacity(0.85)
                            : (flashedInput == id ? Color.white.opacity(0.45) : Color.white.opacity(0.13)))
                sector.stroke(selected ? Color.accentColor : Color.white.opacity(0.22), lineWidth: 1)
                Image(systemName: input?.symbol ?? "circle")
                    .font(.system(size: diameter == nil ? 11 : 9, weight: .bold))
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.75))
                    .offset(offset)
                if keyBindings.isCustomised(id), diameter == nil {
                    Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                        .offset(x: offset.width * 1.45, y: offset.height * 1.45)
                }
            }
            .frame(width: diameter, height: diameter)
            .contentShape(sector)
        }
        .buttonStyle(.plain)
        .help("\(input?.name ?? "Input \(id)"): \(action.summary)")
        .accessibilityLabel("\(input?.name ?? "Input \(id)"), \(action.summary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An annulus sector; angles are SwiftUI's, clockwise from east. An inner
/// ratio of 0 gives a pie slice, which with a full turn is a disc.
private struct RingSector: Shape {
    var start: Angle
    var end: Angle
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        if innerRatio <= 0, end.degrees - start.degrees >= 360 {
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
            return path
        }
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        if innerRatio > 0 {
            path.addArc(center: center, radius: radius * innerRatio, startAngle: end, endAngle: start, clockwise: true)
        } else {
            path.addLine(to: center)
        }
        path.closeSubpath()
        return path
    }

    /// Where a label sits: the middle of the band, at the sector's mid angle.
    func labelOffset(diameter: CGFloat) -> CGSize {
        guard innerRatio > 0 else { return .zero }
        let mid = (start.radians + end.radians) / 2
        let distance = diameter / 2 * (1 + innerRatio) / 2
        return CGSize(width: cos(mid) * distance, height: sin(mid) * distance)
    }
}

#Preview("Controls") {
    ControlsView(bridge: .previewFixture(), initialSelection: [9])
        .frame(width: 1180, height: 860)
}

#Preview("Controls · Multiple Selected") {
    ControlsView(bridge: .previewFixture(), initialSelection: [Pad.dialUpID, Pad.dialDownID, Pad.dialPushID])
        .frame(width: 1180, height: 860)
}
