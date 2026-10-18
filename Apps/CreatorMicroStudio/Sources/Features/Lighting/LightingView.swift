import SwiftUI
import CreatorMicroStudioKit

/// The Studio's saved lighting: underglow, backlight, agent-status looks,
/// per-key at-rest looks and the global brightness and speed.
///
/// Every edit is previewed on the pad straight away through the bridge (unless
/// Live preview is off) and saved to `config.json` once nothing has changed
/// for 3 seconds — or on Save now, leaving the page or the app — so it
/// survives restarts and the bridge keeps repainting it. The Inspector, by
/// contrast, only paints until the Studio repaints.
struct LightingView: View {
    @ObservedObject var bridge: BridgeController

    @State private var draft = LightingPreferences.defaults
    /// The on-disk lighting `draft` was loaded from. A save writes only what
    /// differs from this, merged against the file as it is then.
    @State private var baseline = LightingPreferences.defaults
    @State private var selectedKeys: Set<Int> = []
    @State private var pendingSave: Task<Void, Never>?
    @State private var saveError: String?
    /// An edit whose save failed: kept on screen (and retried) instead of being
    /// replaced by what is on disk.
    @State private var hasUnsavedEdit = false
    @State private var confirmingRestore = false
    /// When the pending save will run, for the header's countdown.
    @State private var saveDeadline: Date?
    /// Off: edits are not painted until they are saved.
    @AppStorage("lightingLivePreview") private var livePreview = true

    /// How long the editor waits after the last change before writing the
    /// file. Long enough to try a few colours without each one being kept.
    private static let saveDelay: TimeInterval = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                persistenceNote
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 14) {
                        keysCard
                        globalCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    VStack(spacing: 14) {
                        underglowCard
                        backlightCard
                        statusCard
                    }
                    .frame(width: 380)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: rebase)
        .onDisappear(perform: flushPendingSave)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            flushPendingSave()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            rebase()
        }
        .onChange(of: livePreview) { on in
            guard pendingSave != nil || hasUnsavedEdit else { return }
            if on {
                bridge.previewLighting(draft)
            } else {
                // Back to what is saved until the save paints the draft.
                bridge.reloadLighting()
            }
        }
        // `$savedLighting` emits on subscribe and from inside `willSet`;
        // skip the first (onAppear rebases anyway) and deliver the rest on
        // the next run-loop turn, outside any view update.
        .onReceive(bridge.$savedLighting.dropFirst().receive(on: RunLoop.main)) { saved in
            // Adopt what is on disk now (the standalone Inspector's "Save to
            // Studio", a hand edit, a reload) unless an edit here is still
            // pending; that edit's save merges against the file instead.
            guard pendingSave == nil, !hasUnsavedEdit else { return }
            draft = saved
            baseline = saved
        }
        .confirmationDialog("Restore the default lighting?", isPresented: $confirmingRestore) {
            Button("Restore defaults", role: .destructive, action: restoreDefaults)
        } message: {
            Text("This removes all saved lighting from config.json, including per-key colours.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Lighting")
                    .font(.largeTitle.weight(.bold))
                Text("How the Studio paints the pad: agent status, underglow, backlight and each key at rest.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            saveStatus
            Toggle("Live preview", isOn: $livePreview)
                .toggleStyle(.switch)
                .help(livePreview
                      ? "Edits show on the pad as you make them"
                      : "The pad only changes when the edit is saved")
            Button {
                confirmingRestore = true
            } label: {
                Label("Restore defaults", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    /// "Previewing — saves in 3 s" with Save now and Revert while an edit is
    /// waiting, then "Saved". Plain status text, not a button.
    @ViewBuilder
    private var saveStatus: some View {
        if pendingSave != nil || hasUnsavedEdit {
            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Label(pendingTitle(at: context.date), systemImage: "circle.dotted")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Save now", action: save)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save the lighting to config.json now (⌘S)")
                Button("Revert", action: revert)
                    .help("Drop the unsaved edit and go back to the saved lighting")
            }
            .controlSize(.small)
        } else {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    private func pendingTitle(at now: Date) -> String {
        let lead = livePreview ? "Previewing" : "Not previewed"
        guard let saveDeadline, pendingSave != nil else { return "\(lead) — not saved" }
        let seconds = max(1, Int(saveDeadline.timeIntervalSince(now).rounded(.up)))
        return "\(lead) — saves in \(seconds) s"
    }

    private var persistenceNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("This is the Studio's saved lighting")
                    .font(.headline)
                Text("Changes show on the pad immediately and are saved to config.json 3 seconds after your last change (or with Save now), so they persist across restarts and come back after the Inspector. Turn off Live preview to change the pad only when a save happens. The Inspector only paints temporarily, until the Studio repaints; use its Save to Studio buttons to keep a look. Nothing here is written to the device keymap or flash.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Per-key looks

    private var keysCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardTitle("KEYS AT REST")
            Text("Select keys to give them a fixed colour. ⌘- or ⇧-click to select several.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LightingPadView(
                looks: draft.keys,
                liveColors: bridge.keyColors,
                globalBrightness: draft.brightness,
                selection: $selectedKeys
            )
            HStack {
                Button("Select all") { selectedKeys = Set(Pad.configurableActionKeyIDs) }
                Button("Select none") { selectedKeys = [] }
                    .disabled(selectedKeys.isEmpty)
                Spacer()
                Text(selectedKeys.isEmpty ? "No keys selected" : "\(selectedKeys.count) selected")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider()
            keyEditor
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var keyEditor: some View {
        if selectedKeys.isEmpty {
            Text("Keys without a fixed colour use the colour of their action, and agent keys show their agent's status.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            let customised = selectedKeys.filter { draft.keys[$0] != nil }
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Fixed colour for \(keyListTitle)", isOn: Binding(
                    get: { !customised.isEmpty },
                    set: { on in
                        if on { updateSelectedKeys { _ in } } else { clearSelectedKeys() }
                    }
                ))
                .toggleStyle(.switch)

                if !customised.isEmpty {
                    LookEditor(
                        look: selectedKeysLook,
                        defaultSpeed: draft.speed,
                        showsBrightness: true,
                        showsSpeed: true
                    )
                    if customised.count < selectedKeys.count {
                        Text("Edits apply to every selected key; keys without a fixed colour get one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                let agentKeys = selectedKeys.filter(showsAgent).sorted()
                if !agentKeys.isEmpty {
                    Text("\(agentKeys.count == 1 ? "Key" : "Keys") \(agentKeys.map(String.init).joined(separator: ", ")) \(agentKeys.count == 1 ? "shows" : "show") an agent's status, so the fixed colour only shows while that slot is empty.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Voice recording still lights its keys while active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keyListTitle: String {
        let keys = selectedKeys.sorted()
        if keys.count == 1 { return "key \(keys[0])" }
        if keys.count <= 4 { return "keys " + keys.map(String.init).joined(separator: ", ") }
        return "\(keys.count) keys"
    }

    /// A slot key on Focus Agent: it paints agent status, not its at-rest look.
    private func showsAgent(_ key: Int) -> Bool {
        Pad.agentSlot(for: key) != nil && bridge.keyBindings.action(for: key) == .focusAgent
    }

    /// The look of the lowest selected key with one; writes go to every
    /// selected key, field by field, so differing colours survive an effect change.
    private var selectedKeysLook: Binding<LightingPreferences.Look> {
        Binding(
            get: {
                selectedKeys.sorted().lazy.compactMap { draft.keys[$0] }.first ?? Self.newKeyLook
            },
            set: { next in
                let current = selectedKeys.sorted().lazy.compactMap { draft.keys[$0] }.first ?? Self.newKeyLook
                updateSelectedKeys { look in
                    if next.color != current.color { look.color = next.color }
                    if next.effect != current.effect { look.effect = next.effect }
                    if next.brightness != current.brightness { look.brightness = next.brightness }
                    if next.speed != current.speed { look.speed = next.speed }
                }
            }
        )
    }

    private static let newKeyLook = LightingPreferences.Look(color: 0xFFFFFF, effect: .solid, brightness: 0.6)

    private func updateSelectedKeys(_ body: (inout LightingPreferences.Look) -> Void) {
        var next = draft
        for key in selectedKeys where Pad.configurableActionKeyIDs.contains(key) {
            var look = next.keys[key] ?? selectedKeys.sorted().lazy.compactMap { draft.keys[$0] }.first ?? Self.newKeyLook
            body(&look)
            next.keys[key] = look
        }
        commit(next)
    }

    private func clearSelectedKeys() {
        var next = draft
        for key in selectedKeys { next.keys.removeValue(forKey: key) }
        commit(next)
    }

    // MARK: - Global

    private var globalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("WHOLE PAD")
            UnitSlider(title: "Brightness", value: editable.brightness)
            Text("Multiplies every key, the underglow and the backlight.")
                .font(.caption)
                .foregroundStyle(.secondary)
            UnitSlider(title: "Speed", value: editable.speed)
            Text("Effect speed for anything that does not set its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Zones

    private var underglowCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("UNDERGLOW")
            Picker("Mode", selection: editable.underglow.mode) {
                ForEach(LightingPreferences.UnderglowMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch draft.underglow.mode {
            case .status:
                Text("Follows the agent that most needs you, in the status colours below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .custom:
                LookEditor(look: editable.underglow.look, defaultSpeed: draft.speed,
                           showsBrightness: true, showsSpeed: true)
            case .off:
                Text("The underglow stays dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var backlightCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("BACKLIGHT")
            Picker("Mode", selection: editable.backlight.mode) {
                ForEach(LightingPreferences.BacklightMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            switch draft.backlight.mode {
            case .off:
                Text("Keys show only their own colours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .custom:
                LookEditor(look: editable.backlight.look, defaultSpeed: draft.speed,
                           showsBrightness: true, showsSpeed: true)
                Text("A plate-wide look under the keys. Key colours paint over it, so it shows through unlit keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardTitle("AGENT STATUS")
            ForEach(LightingPreferences.statusStates, id: \.self) { state in
                HStack(spacing: 10) {
                    ColorPicker(Self.statusTitle(state), selection: colorBinding(statusLook(state).color),
                                supportsOpacity: false)
                        .labelsHidden()
                        .accessibilityLabel("\(Self.statusTitle(state)) colour")
                    Text(Self.statusTitle(state))
                        .frame(width: 84, alignment: .leading)
                        .accessibilityHidden(true)
                    Spacer(minLength: 4)
                    EffectPicker(effect: statusLook(state).effect, title: "\(Self.statusTitle(state)) effect")
                        .frame(width: 150)
                }
            }
            Text("Agent keys and the status underglow use these. Unknown follows Idle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statusLook(_ state: String) -> Binding<LightingPreferences.Look> {
        Binding(
            get: { draft.look(forStatus: state) },
            set: { look in
                var next = draft
                next.status[state] = look
                commit(next)
            }
        )
    }

    private static func statusTitle(_ state: String) -> String {
        switch state {
        case "blocked": return "Needs you"
        case "working": return "Working"
        case "done": return "Done"
        case "idle": return "Idle"
        default: return state.capitalized
        }
    }

    // MARK: - Editing

    /// The draft, with every write previewed and queued for saving.
    private var editable: Binding<LightingPreferences> {
        Binding(get: { draft }, set: { commit($0) })
    }

    private func commit(_ next: LightingPreferences) {
        guard next != draft else { return }
        draft = next
        saveError = nil
        if livePreview { bridge.previewLighting(next) }
        scheduleSave()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        saveDeadline = Date().addingTimeInterval(Self.saveDelay)
        pendingSave = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.saveDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Drops the unsaved edit: the pad and the editor go back to the file.
    private func revert() {
        pendingSave?.cancel()
        pendingSave = nil
        saveDeadline = nil
        hasUnsavedEdit = false
        saveError = nil
        bridge.reloadLighting()
        draft = bridge.savedLighting
        baseline = bridge.savedLighting
    }

    private func flushPendingSave() {
        guard pendingSave != nil || hasUnsavedEdit else { return }
        save()
    }

    /// Re-reads the file so the draft starts from what is on disk now — on
    /// appear and whenever the app becomes active, since another process may
    /// have written meanwhile. A pending edit is saved (merged) first.
    private func rebase() {
        if pendingSave != nil || hasUnsavedEdit {
            save()
            // Keep the edit on screen when it could not be saved.
            guard saveError == nil else { return }
        } else {
            bridge.reloadLighting()
        }
        draft = bridge.savedLighting
        baseline = bridge.savedLighting
    }

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        saveDeadline = nil
        do {
            try bridge.saveLighting(draft, baseline: baseline)
            hasUnsavedEdit = false
            saveError = nil
            // Adopt the file explicitly: the publish during saveLighting is
            // skipped by the onReceive guard when an earlier save had failed
            // (hasUnsavedEdit was still true), which would leave the baseline
            // stale and make the next merge drop a change back to it.
            draft = bridge.savedLighting
            baseline = bridge.savedLighting
        } catch {
            hasUnsavedEdit = true
            saveError = "Couldn't save the lighting: \(error.localizedDescription)"
        }
    }

    private func restoreDefaults() {
        pendingSave?.cancel()
        pendingSave = nil
        saveDeadline = nil
        hasUnsavedEdit = false
        do {
            try bridge.restoreDefaultLighting()
            saveError = nil
        } catch {
            saveError = "Couldn't restore the default lighting: \(error.localizedDescription)"
            bridge.reloadLighting()
        }
        draft = bridge.savedLighting
        baseline = bridge.savedLighting
    }

    private func cardTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(1)
    }
}

// MARK: - Controls

private func colorBinding(_ packed: Binding<Int>) -> Binding<Color> {
    Binding(get: { Color(packedRGB: packed.wrappedValue) }, set: { packed.wrappedValue = $0.packedRGB })
}

/// Colour, effect and optionally brightness and speed for one look.
private struct LookEditor: View {
    @Binding var look: LightingPreferences.Look
    /// What a look without its own speed runs at.
    let defaultSpeed: Double
    let showsBrightness: Bool
    let showsSpeed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ColorPicker("Colour", selection: colorBinding($look.color), supportsOpacity: false)
                Text(hexString(look.color))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                EffectPicker(effect: $look.effect)
                    .frame(width: 150)
            }
            if showsBrightness {
                UnitSlider(title: "Brightness", value: Binding(
                    get: { look.brightness ?? 1 }, set: { look.brightness = $0 }))
            }
            if showsSpeed {
                UnitSlider(title: "Speed", value: Binding(
                    get: { look.speed ?? defaultSpeed }, set: { look.speed = $0 }))
                    .disabled(look.effect == .solid || look.effect == .off)
            }
        }
    }
}

private struct EffectPicker: View {
    @Binding var effect: OAI.Effect
    /// The accessible name; the label itself is hidden.
    var title: String = "Effect"

    var body: some View {
        Picker(title, selection: $effect) {
            ForEach(OAI.Effect.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel(title)
    }
}

/// A 0...1 slider shown as a percentage.
private struct UnitSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 76, alignment: .leading)
            Slider(value: $value, in: 0...1)
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Pad drawing

/// A small pad drawing for picking keys. Keys with a saved look show it;
/// others show what the bridge paints now, faintly. The dial, joystick and
/// case mark have no LEDs and are not selectable.
private struct LightingPadView: View {
    let looks: [Int: LightingPreferences.Look]
    let liveColors: [Int: Color]
    let globalBrightness: Double
    @Binding var selection: Set<Int>

    private let keySize = CGSize(width: 66, height: 54)
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
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Key selection for at-rest lighting")
    }

    @ViewBuilder
    private func cellView(_ cell: Pad.DisplayCell) -> some View {
        switch cell {
        case .key(let key): keyButton(key)
        case .dial: control(symbol: "dial.medium", label: "Dial")
        case .joystick: control(symbol: "dpad", label: "Joystick")
        case .caseMark:
            Circle()
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                .frame(width: 30, height: 30)
                .frame(width: keySize.width, height: keySize.height)
                .accessibilityHidden(true)
        }
    }

    private func keyButton(_ key: Int) -> some View {
        let look = looks[key]
        let selected = selection.contains(key)
        let fill: Color = {
            if let look, look.effect != .off {
                let level = globalBrightness * (look.brightness ?? 1)
                return Color(packedRGB: look.color).opacity(0.25 + 0.75 * level)
            }
            if let live = liveColors[key] { return live.opacity(0.28) }
            return Color.white.opacity(0.06)
        }()
        return Button {
            toggle(key)
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(look == nil ? 0.15 : 0.45),
                                      lineWidth: selected ? 3 : 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(key)")
                        .font(.system(.caption2, design: .monospaced).weight(.medium))
                        .foregroundStyle(look == nil ? .white.opacity(0.55) : .black.opacity(0.62))
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if look != nil {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.black.opacity(0.5))
                            .padding(6)
                    }
                }
                .frame(width: keySize.width, height: keySize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Key \(key)\(look == nil ? "" : ", fixed colour \(hexString(look!.color))")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(look == nil ? "Key \(key): action colour" : "Key \(key): \(hexString(look!.color)), \(look!.effect.label)")
    }

    private func control(symbol: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
            Text("No LED")
                .font(.system(size: 9))
        }
        .foregroundStyle(.white.opacity(0.32))
        .frame(width: keySize.width, height: keySize.height)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("\(label), no LED")
    }

    /// Plain click selects one key; ⌘- or ⇧-click adds or removes it.
    private func toggle(_ key: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            if selection.contains(key) { selection.remove(key) } else { selection.insert(key) }
        } else {
            selection = selection == [key] ? [] : [key]
        }
    }
}

#Preview("Lighting") {
    LightingView(bridge: .previewFixture())
        .frame(width: 1100, height: 900)
        .allowsHitTesting(false)
}
