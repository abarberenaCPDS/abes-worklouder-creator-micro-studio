import XCTest
@testable import CreatorMicroStudioKit

/// The keymap write path against a scripted pad: how many flash writes it
/// costs, what it writes, and how it reads a firmware that answers `{"ok":1}`
/// but keeps some of its old codes. Nothing here touches IOKit.
@MainActor
final class KeymapApplyTests: XCTestCase {

    /// An in-memory `keymap.json` behind `fs.read` / `fs.write`.
    private final class ScriptedPad {
        enum WriteBehaviour {
            /// Saves the file as sent.
            case accept
            /// Saves it but keeps the old dial push code.
            case keepDialPush
            /// Throws the whole file away if it has AG19 anywhere.
            case rejectFileWithAG19
            /// Throws every file away.
            case rejectAll
        }

        var keymap: [String: Any]
        var behaviour: WriteBehaviour = .accept
        /// Saves (per `behaviour`) but never answers.
        var writeTimesOut = false
        /// Answers the write with an RPC error (after applying `behaviour`).
        var writeError: String?
        /// Every `fs.read` after the first write fails, as if the link dropped.
        var readsFailAfterWrite = false
        private(set) var writes: [String] = []
        private(set) var reads = 0

        init(keymap: [String: Any]) { self.keymap = keymap }

        func call(_ method: String, _ params: [String: Any]) async throws -> Any? {
            switch method {
            case "fs.read":
                reads += 1
                if readsFailAfterWrite, !writes.isEmpty { throw WLDevice.Failure.notConnected }
                let data = try JSONSerialization.data(withJSONObject: keymap)
                return ["data": String(decoding: data, as: UTF8.self)]
            case "fs.write":
                let text = try XCTUnwrap(params["data"] as? String)
                writes.append(text)
                let next = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                switch behaviour {
                case .accept: keymap = next
                case .keepDialPush: keymap = Self.withDialPush(Self.dialPush(keymap), in: next)
                case .rejectFileWithAG19: if !text.contains("KV_OAI_AG19") { keymap = next }
                case .rejectAll: break
                }
                if writeTimesOut { throw WLDevice.Failure.timeout("fs.write") }
                if let writeError { throw HerdrError.api(writeError) }
                return ["ok": 1]
            default:
                XCTFail("unexpected \(method)")
                return nil
            }
        }

        static func dialPush(_ config: [String: Any]) -> String? {
            guard let dial = (KeymapManager.activeLayerLayout(config)?["encoders"] as? [[String]])?.first,
                  dial.count > 2 else { return nil }
            return dial[2]
        }

        static func withDialPush(_ code: String?, in config: [String: Any]) -> [String: Any] {
            var next = config
            var profiles = next["profiles"] as! [[String: Any]]
            let index = (next["activeProfileId"] as? Int ?? 0) < profiles.count ? (next["activeProfileId"] as? Int ?? 0) : 0
            var layers = profiles[index]["layers"] as! [[String: Any]]
            var layout = layers[0]["layout"] as! [String: Any]
            var encoders = layout["encoders"] as! [[String]]
            encoders[0][2] = code ?? "KC_MPLY"
            layout["encoders"] = encoders
            layers[0]["layout"] = layout
            profiles[index]["layers"] = layers
            next["profiles"] = profiles
            return next
        }
    }

    private func stockKeymap() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "stock-keymap", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try KeymapManager.parse(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }

    /// What 0.2.x left on a pad: everything bound except the dial push.
    private func boundBy02x() throws -> [String: Any] {
        try KeymapManager.withAgentKeymap(try stockKeymap(), includeDialPush: false)
    }

    private func apply(_ pad: ScriptedPad, dialPushRejected: Bool = false, mayWrite: Bool = true) async throws -> KeymapManager.Outcome {
        try await KeymapManager.apply(dialPushRejected: dialPushRejected, mayWrite: mayWrite,
                                      timing: .immediate, call: pad.call)
    }

    func testFullyBoundPadIsNotWritten() async throws {
        let pad = ScriptedPad(keymap: try KeymapManager.withAgentKeymap(try stockKeymap()))
        let outcome = try await apply(pad)
        XCTAssertEqual(outcome, .unchanged)
        XCTAssertTrue(pad.writes.isEmpty)
        XCTAssertEqual(pad.reads, 1)
    }

    func testStockPadIsWrittenOnceAndVerified() async throws {
        let pad = ScriptedPad(keymap: try stockKeymap())
        let outcome = try await apply(pad)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(pad.writes.count, 1)
        XCTAssertTrue(pad.writes[0].contains("KV_OAI_AG19"))
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(pad.keymap))
    }

    /// The firmware keeps play/pause on the push: that is a success without
    /// the push, not an error, and it costs exactly one write.
    func testDroppedDialPushIsAppliedWithoutItAfterOneWrite() async throws {
        let pad = ScriptedPad(keymap: try boundBy02x())
        pad.behaviour = .keepDialPush
        let outcome = try await apply(pad)
        XCTAssertEqual(outcome, .appliedWithoutDialPush(found: "KC_MPLY"))
        XCTAssertFalse(outcome.dialPushBound)
        XCTAssertEqual(pad.writes.count, 1, "no fallback write: the core bindings stuck")
        XCTAssertTrue(KeymapManager.isCoreKeymapApplied(pad.keymap))
    }

    /// Once the rejection is on record, the next connect reads and stops.
    func testKnownDialPushRejectionDoesNotRewrite() async throws {
        let pad = ScriptedPad(keymap: try boundBy02x())
        pad.behaviour = .keepDialPush
        let outcome = try await apply(pad, dialPushRejected: true)
        XCTAssertEqual(outcome, .dialPushUnavailable(found: "KC_MPLY"))
        XCTAssertFalse(outcome.wroteFlash)
        XCTAssertTrue(pad.writes.isEmpty)
        XCTAssertEqual(pad.reads, 1)
    }

    /// A known rejection still binds missing keys, just without AG19.
    func testKnownDialPushRejectionStillBindsMissingKeysWithoutAG19() async throws {
        let pad = ScriptedPad(keymap: try stockKeymap())
        let outcome = try await apply(pad, dialPushRejected: true)
        XCTAssertEqual(outcome, .appliedWithoutDialPush(found: "KC_MPLY"))
        XCTAssertEqual(pad.writes.count, 1)
        XCTAssertFalse(pad.writes[0].contains("KV_OAI_AG19"))
    }

    /// Firmware that throws the whole file away over AG19 gets exactly one
    /// fallback write without it, which sticks.
    func testCoreMissingGetsExactlyOneFallbackWriteWithoutAG19() async throws {
        var stock = try stockKeymap()
        stock = ScriptedPad.withDialPush("KC_MPLY", in: stock)
        let pad = ScriptedPad(keymap: stock)
        pad.behaviour = .rejectFileWithAG19
        let outcome = try await apply(pad)
        XCTAssertEqual(outcome, .appliedWithoutDialPush(found: "KC_MPLY"))
        XCTAssertEqual(pad.writes.count, 2)
        XCTAssertTrue(pad.writes[0].contains("KV_OAI_AG19"))
        XCTAssertFalse(pad.writes[1].contains("KV_OAI_AG19"))
        XCTAssertTrue(KeymapManager.isCoreKeymapApplied(pad.keymap))
    }

    func testRefusedKeymapFailsAfterTwoWritesNamingWhatIsMissing() async throws {
        let pad = ScriptedPad(keymap: try boundBy02x())
        // Knock joystick right back to stock so the core is incomplete.
        var config = pad.keymap
        var profiles = config["profiles"] as! [[String: Any]]
        let index = (config["activeProfileId"] as? Int ?? 0) < profiles.count ? (config["activeProfileId"] as? Int ?? 0) : 0
        var layers = profiles[index]["layers"] as! [[String: Any]]
        var layout = layers[0]["layout"] as! [String: Any]
        var joystick = layout["joystick"] as! [String: Any]
        var sectors = joystick["sectors"] as! [[String: Any]]
        for i in sectors.indices where (sectors[i]["k"] as? String) == "KV_OAI_AG18" { sectors[i]["k"] = "KC_RIGHT" }
        joystick["sectors"] = sectors
        layout["joystick"] = joystick
        layers[0]["layout"] = layout
        profiles[index]["layers"] = layers
        config["profiles"] = profiles
        pad.keymap = config
        pad.behaviour = .rejectAll

        do {
            _ = try await apply(pad)
            XCTFail("a refused keymap must not read as applied")
        } catch let failure as KeymapManager.Failure {
            guard case .notAccepted(let missing) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(Set(missing.map(\.inputID)), [Pad.joyEastID, Pad.dialPushID])
            let text = failure.localizedDescription
            XCTAssertTrue(text.contains("Joystick right (has KC_RIGHT)"), text)
            XCTAssertTrue(text.contains("Dial push (has KC_MPLY)"), text)
            XCTAssertTrue(text.contains("Lighting still works"), text)
            XCTAssertTrue(text.contains("until you retry"), text)
        }
        XCTAssertEqual(pad.writes.count, 2, "at most two writes per connection")
    }

    /// A write the pad never answered but did save counts as applied.
    func testTimedOutWriteThatReadsBackIsSuccess() async throws {
        let pad = ScriptedPad(keymap: try stockKeymap())
        pad.writeTimesOut = true
        let outcome = try await apply(pad)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(pad.writes.count, 1)
    }

    func testWriteErrorWithNoReadBackIsWriteFailedAfterOneWrite() async throws {
        let pad = ScriptedPad(keymap: try stockKeymap())
        pad.writeError = "flash busy"
        pad.readsFailAfterWrite = true
        do {
            _ = try await apply(pad)
            XCTFail("expected writeFailed")
        } catch let failure as KeymapManager.Failure {
            guard case .writeFailed = failure else { return XCTFail("got \(failure)") }
            XCTAssertTrue(failure.mayHaveWritten)
        }
        XCTAssertEqual(pad.writes.count, 1, "no fallback write when nothing could be read back")
    }

    func testTimedOutWriteWithNoReadBackIsUnconfirmed() async throws {
        let pad = ScriptedPad(keymap: try stockKeymap())
        pad.writeTimesOut = true
        pad.readsFailAfterWrite = true
        do {
            _ = try await apply(pad)
            XCTFail("expected unconfirmed")
        } catch let failure as KeymapManager.Failure {
            XCTAssertEqual(failure, .unconfirmed)
            XCTAssertTrue(failure.mayHaveWritten)
        }
        XCTAssertEqual(pad.writes.count, 1)
    }

    func testWriteErrorThatReadsBackIsJudgedByTheReadBack() async throws {
        let pad = ScriptedPad(keymap: try stockKeymap())
        pad.writeError = "late error"
        let outcome = try await apply(pad)
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(pad.writes.count, 1)
    }

    func testRecordsHonourAnyFirmwareWhenTheVersionIsUnknown() {
        let records = freshRecords()
        XCTAssertFalse(records.anyDialPushRejected())
        XCTAssertFalse(records.anyNotAccepted())
        records.setDialPushRejected(true, firmware: "0.6.0-rc.10")
        records.setNotAccepted(true, firmware: "0.6.0-rc.10")
        XCTAssertTrue(records.anyDialPushRejected())
        XCTAssertTrue(records.anyNotAccepted())
        records.clear(firmware: "0.6.0-rc.10")
        XCTAssertFalse(records.anyDialPushRejected())
    }

    func testNoWriteAllowedReportsWithoutWriting() async throws {
        let pad = ScriptedPad(keymap: try stockKeymap())
        do {
            _ = try await apply(pad, mayWrite: false)
            XCTFail("expected notAccepted")
        } catch KeymapManager.Failure.notAccepted(let missing) {
            XCTAssertTrue(missing.contains { $0.inputID == 0 })
            XCTAssertTrue(KeymapManager.Failure.notAccepted(missing: missing).localizedDescription
                .contains("Per-key lighting won't work"))
        }
        XCTAssertTrue(pad.writes.isEmpty)
    }

    func testMissingBindingsDiffNamesWhatThePadHas() throws {
        let missing = KeymapManager.missingBindings(try boundBy02x())
        XCTAssertEqual(missing, [KeymapManager.MissingBinding(inputID: Pad.dialPushID,
                                                              expected: "KV_OAI_AG19", found: "KC_MPLY")])
        XCTAssertTrue(KeymapManager.isCoreKeymapApplied(try boundBy02x()))
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(try boundBy02x()))
    }

    func testWithoutDialPushLeavesThePressAlone() throws {
        let next = try KeymapManager.withAgentKeymap(try stockKeymap(), includeDialPush: false)
        XCTAssertEqual(ScriptedPad.dialPush(next), "KC_MPLY")
    }

    // MARK: - Records and the bridge

    private func freshRecords() -> KeymapRecords {
        let suite = "dev.abeisonai.worklouder.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return KeymapRecords(defaults: defaults)
    }

    func testRecordsArePerFirmwareAndClear() {
        let records = freshRecords()
        records.setDialPushRejected(true, firmware: "1.0")
        records.setNotAccepted(true, firmware: "1.0")
        XCTAssertTrue(records.dialPushRejected(firmware: "1.0"))
        XCTAssertFalse(records.dialPushRejected(firmware: "1.1"), "a firmware update gets a fresh try")
        records.clear(firmware: "1.0")
        XCTAssertFalse(records.dialPushRejected(firmware: "1.0"))
        XCTAssertFalse(records.notAccepted(firmware: "1.0"))
    }

    private func bridge(records: KeymapRecords) -> BridgeController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bridge = BridgeController(
            store: StudioConfigStore(path: directory.appendingPathComponent("config.json").path),
            keymapRecords: records
        )
        bridge.keymapTiming = .immediate
        return bridge
    }

    /// The full path: the first connect writes once and records the
    /// refusal; a reconnect and a relaunch never write again.
    func testBridgeRecordsDialPushRefusalAndNeverRewrites() async {
        let records = freshRecords()
        let pad = PadEmulator()
        pad.keepsDialPushCode = true

        let first = bridge(records: records)
        first.useEmulatorForTesting(pad)
        await first.openDeviceForTesting()
        XCTAssertTrue(first.keymapReady)
        XCTAssertFalse(first.dialPushAvailable)
        XCTAssertEqual(first.dialPushFirmwareCode, "KC_MPLY")
        XCTAssertNil(first.deviceError, "a refused AG19 is not an error")
        XCTAssertEqual(pad.keymapWrites, 1)
        XCTAssertTrue(records.dialPushRejected(firmware: PadEmulator.firmware))

        // Bluetooth reconnect in the same run: not even a read is needed.
        await first.openDeviceForTesting()
        XCTAssertEqual(pad.keymapWrites, 1)

        // Relaunch: a new bridge reads, sees the known refusal, writes nothing.
        let second = bridge(records: records)
        second.useEmulatorForTesting(pad)
        await second.openDeviceForTesting()
        XCTAssertEqual(pad.keymapWrites, 1)
        XCTAssertTrue(second.keymapReady)
        XCTAssertFalse(second.dialPushAvailable)
    }

    func testDialPushDefaultStopsNeedingAccessibilityWhenUnavailable() async {
        let records = freshRecords()
        let pad = PadEmulator()
        pad.keepsDialPushCode = true
        let bridge = bridge(records: records)
        bridge.useBindings(KeyBindings(actions: [:]))
        XCTAssertTrue(bridge.inputsRequiringAccessibility.contains(Pad.dialPushID),
                      "the default play/pause needs Accessibility")
        bridge.useEmulatorForTesting(pad)
        await bridge.openDeviceForTesting()
        XCTAssertFalse(bridge.inputsRequiringAccessibility.contains(Pad.dialPushID))
    }
}
