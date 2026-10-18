import Foundation
import CreatorMicroStudioKit

/// The model and effort actions: effort and model for whichever agent has
/// focus. By default the dial steps effort and the joystick works the model
/// list, but any input can be bound to any of these through `config.json`.
///
/// Claude Code takes orders directly — `/effort <level>` and `/model <name>`
/// are commands, so effort climbs a ladder and models cycle a list, both
/// configurable. Codex has bindable effort commands but only a picker for
/// models, so its effort steps send the chords bound in `[tui.keymap]` and its
/// model steps drive the `/model` picker: the first step opens it, later steps
/// move, confirm and cancel close it.
///
/// Either way the model list is one you cannot see from the pad, so every
/// model step also puts that list on screen — see `TunePanelController`.
@MainActor
final class TuneController {

    static let shared = TuneController()

    /// The chords `~/.codex/config.toml` binds to
    /// `chat.increase_reasoning_effort` / `chat.decrease_reasoning_effort`.
    static let codexEffortUpChord = "ctrl+alt+u"
    static let codexEffortDownChord = "ctrl+alt+d"

    var onError: ((String) -> Void)?
    /// The bridge owns the loaded config; this reads through to it.
    var bindings: () -> KeyBindings = { KeyBindings() }

    /// Where each Claude pane sits on the effort ladder and model list. Blind
    /// state: it starts at the defaults and follows our own commands, so a
    /// change made by hand inside the session drifts it until the next nudge.
    private var claudeEffortIndex: [String: Int] = [:]
    private var claudeModelIndex: [String: Int] = [:]

    /// The codex pane whose `/model` picker we opened, if any. Model steps
    /// steer the picker only while this is fresh; a stale entry means the
    /// picker was dealt with by hand.
    private var codexPickerPane: String?
    private var codexPickerOpened: Date?
    private static let pickerLifetime: TimeInterval = 30

    // MARK: - Entry point

    /// The bridge's `onTune` callback.
    func handle(_ command: TuneCommand) {
        switch command {
        case .effortUp: stepEffort(1)
        case .effortDown: stepEffort(-1)
        case .modelNext: stepModel(1)
        case .modelPrevious: stepModel(-1)
        case .pickerConfirm: confirmPicker()
        case .pickerCancel: cancelPicker()
        }
    }

    // MARK: - Effort

    /// +1 for more effort, -1 for less.
    func stepEffort(_ step: Int) {
        Task { await effort(step) }
    }

    private func effort(_ step: Int) async {
        guard let (agent, pane) = await focusedPane() else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                let ladder = bindings().claudeEfforts
                let index = climb(claudeEffortIndex[pane] ?? ladder.count / 2,
                                  by: step, within: ladder.count)
                claudeEffortIndex[pane] = index
                try await send(command: "/effort \(ladder[index])", to: pane)
            } else if kind.contains("codex") {
                try await HerdrClient.sendKeys(
                    paneID: pane,
                    keys: [step > 0 ? Self.codexEffortUpChord : Self.codexEffortDownChord]
                )
            } else {
                onError?("No effort control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Clamped, not wrapping: turning past the top should pin at max, not
    /// jump to low — a dial has ends even when the hardware spins freely.
    private func climb(_ index: Int, by step: Int, within count: Int) -> Int {
        max(0, min(count - 1, index + step))
    }

    // MARK: - Model

    /// +1 for the next model down the list, -1 for the one above.
    func stepModel(_ step: Int) {
        Task { await model(step) }
    }

    /// Confirms an open Codex picker. Claude switches on every step, so it
    /// has nothing to confirm.
    func confirmPicker() {
        Task { await closePicker(confirm: true) }
    }

    /// Cancels an open Codex picker.
    func cancelPicker() {
        Task { await closePicker(confirm: false) }
    }

    private func model(_ step: Int) async {
        guard let (agent, pane) = await focusedPane() else { return }
        let kind = agent.agent.lowercased()
        do {
            if kind.contains("claude") {
                try await claudeModel(step, pane: pane, agent: agent.shortName)
            } else if kind.contains("codex") {
                try await codexModel(step, pane: pane, agent: agent.shortName)
            } else {
                onError?("No model control for \(agent.agent).")
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    /// Models cycle with wraparound — unlike effort, a list of names has no
    /// natural top or bottom.
    private func claudeModel(_ step: Int, pane: String, agent: String) async throws {
        let models = bindings().claudeModels
        guard !models.isEmpty else { return }
        let index = ((claudeModelIndex[pane] ?? 0) + step % models.count + models.count) % models.count
        claudeModelIndex[pane] = index
        // Up before the command goes out: the panel is the answer to "what did
        // I just land on", and waiting for the TUI to echo would show it late.
        TunePanelController.shared.showModels(
            models,
            current: index,
            agent: agent,
            hint: "next and previous model cycle the list"
        )
        try await send(command: "/model \(models[index])", to: pane)
    }

    private var codexPickerIsOpen: Bool {
        codexPickerPane != nil
            && Date().timeIntervalSince(codexPickerOpened ?? .distantPast) < Self.pickerLifetime
    }

    private func codexModel(_ step: Int, pane: String, agent: String) async throws {
        guard codexPickerIsOpen, codexPickerPane == pane else {
            // The first step opens the picker; the rest is steering.
            try await send(command: "/model", to: pane)
            codexPickerPane = pane
            codexPickerOpened = Date()
            showCodexModels(agent: agent)
            return
        }
        try await HerdrClient.sendKeys(paneID: pane, keys: [step < 0 ? "up" : "down"])
        codexPickerOpened = Date()
        showCodexModels(agent: agent)
    }

    private func closePicker(confirm: Bool) async {
        // Only a picker this controller opened, in the pane that still has
        // focus, is ours to close.
        guard codexPickerIsOpen, let pane = codexPickerPane else { return }
        guard let (_, focused) = await focusedPane(), focused == pane else {
            codexPickerPane = nil
            return
        }
        do {
            try await HerdrClient.sendKeys(paneID: pane, keys: [confirm ? "enter" : "esc"])
        } catch {
            onError?(error.localizedDescription)
        }
        codexPickerPane = nil
        TunePanelController.shared.hide()
    }

    /// Codex's picker is its own; we push arrow keys at it without being told
    /// where the cursor sits, so the panel is a numbered reading of the list
    /// and nothing is marked as current.
    private func showCodexModels(agent: String) {
        TunePanelController.shared.showModels(
            bindings().codexModels,
            current: nil,
            agent: agent,
            hint: "next/previous model move · confirm and cancel close the picker"
        )
    }

    // MARK: - Plumbing

    private func focusedPane() async -> (HerdrAgent, String)? {
        guard let agent = try? await HerdrClient.focusedAgent(), let pane = agent.paneID else {
            onError?("Nothing has focus in Herdr right now.")
            return nil
        }
        return (agent, pane)
    }

    /// Slash commands go in as text plus enter: typed, then submitted.
    private func send(command: String, to pane: String) async throws {
        try await HerdrClient.sendText(paneID: pane, text: command)
        try await HerdrClient.sendKeys(paneID: pane, keys: ["enter"])
    }
}
