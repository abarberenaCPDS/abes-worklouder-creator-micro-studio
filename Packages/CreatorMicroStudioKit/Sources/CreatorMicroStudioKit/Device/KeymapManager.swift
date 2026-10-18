import Foundation

/// Device keymap handling.
///
/// Per-key lighting only works on keys bound to `KV_OAI_AG*` keycodes, and only
/// when those bindings are on the ACTIVE layer — parking them on a spare layer
/// does nothing. Nothing reports a mismatch: `v.oai.thstatus` still answers
/// `{"ok":1}` for a key it cannot light, so a wrong keymap looks exactly like a
/// working one from the host side. Hence checking rather than assuming.
///
/// The file itself is double-encoded: `fs.read` returns `{"data": "<json>"}`
/// where the inner string is the real config.
public enum KeymapManager {

    /// Indexed by key: key N is bound to `agCodes[N]`.
    public static let agCodes = [
        "KV_OAI_AG00", "KV_OAI_AG01", "KV_OAI_AG02",
        "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05",
        "KV_OAI_AG06", "KV_OAI_AG07", "KV_OAI_AG08",
        "KV_OAI_AG09", "KV_OAI_AG10", "KV_OAI_AG11",
        "KV_OAI_AG12",
    ]

    /// The dial, in `encoders[0]` order: clockwise, counter-clockwise, press.
    /// The press takes AG19, the last free id, so a click reports like any
    /// other input; its stock `KC_MPLY` lives on as the dial push's default
    /// host-side action (play/pause), and it can be remapped from there.
    static let dialCodes = ["KV_OAI_AG13", "KV_OAI_AG14", "KV_OAI_AG19"]

    /// The joystick's four cardinal sectors, matched by the angle at their
    /// centre in the radial map. Diagonal sectors are left alone.
    static let joystickCodes: [(centre: Double, code: String)] = [
        (0.25, "KV_OAI_AG15"),
        (0.50, "KV_OAI_AG16"),
        (0.75, "KV_OAI_AG17"),
        (0.00, "KV_OAI_AG18"),
    ]

    /// A sector's centre angle, handling the one that wraps through zero.
    static func sectorCentre(_ a1: Double, _ a2: Double) -> Double {
        let centre = a2 >= a1 ? (a1 + a2) / 2 : ((a1 + a2 + 1) / 2)
        return centre.truncatingRemainder(dividingBy: 1)
    }

    /// The keycode each managed key must carry, addressed by its position in
    /// the [2, 4, 4, 3] matrix. Bindings are per key rather than per row: a
    /// row can hold keys this app has no business touching, and rewriting the
    /// whole row would take their keycodes with it.
    static var bindings: [(row: Int, column: Int, code: String)] {
        Pad.boundKeyIDs.compactMap { key in
            guard key < agCodes.count, let at = Pad.position(of: key) else { return nil }
            return (at.row, at.column, agCodes[key])
        }
    }

    /// A slot that does not carry the AG code the Studio needs, with what
    /// the pad has there instead — the expected-vs-read-back diff.
    public struct MissingBinding: Equatable, Sendable {
        /// The input (= AG thread id) the slot belongs to.
        public let inputID: Int
        public let expected: String
        /// The keycode read back, or nil when the slot is absent.
        public let found: String?

        public var isDialPush: Bool { inputID == Pad.dialPushID }

        /// "Dial push (has KC_MPLY)".
        public var description: String {
            let name = Pad.input(inputID)?.name ?? expected
            guard let found, !found.isEmpty else { return name }
            return "\(name) (has \(found))"
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case noProfiles
        /// The pad answered the write but kept its old codes in these slots.
        case notAccepted(missing: [MissingBinding])
        /// The write went unanswered and the read-back did not come either:
        /// the pad may or may not have saved it.
        case unconfirmed
        /// The pad answered the write with an error, or the link dropped
        /// mid-write, and nothing could be read back afterwards.
        case writeFailed(String)
        case unreadable(String)

        /// Whether a flash write may have reached the pad. Studio does not
        /// write again after one of these until the user retries.
        public var mayHaveWritten: Bool {
            switch self {
            case .notAccepted, .unconfirmed, .writeFailed: return true
            case .noProfiles, .unreadable: return false
            }
        }

        public var errorDescription: String? {
            switch self {
            case .noProfiles: return "Device keymap has no profiles."
            case .notAccepted(let missing):
                let list = missing.map(\.description).joined(separator: ", ")
                let keysMissing = missing.contains { (0..<Pad.keyCount).contains($0.inputID) }
                let lighting = keysMissing
                    ? "Per-key lighting won't work on those keys"
                    : "Lighting still works"
                return "The pad kept its old bindings for: \(list). \(lighting); Studio won't rewrite the pad until you retry."
            case .unconfirmed:
                return "The pad didn't confirm it saved its bindings. Studio won't write to the pad again until you retry."
            case .writeFailed(let detail):
                return "The pad didn't take the keymap write (\(detail)). Studio won't write to the pad again until you retry."
            case .unreadable(let detail): return "Could not read the device keymap: \(detail)"
            }
        }
    }

    /// What `apply` found and did.
    public enum Outcome: Equatable, Sendable {
        /// Everything was already bound; nothing written.
        case unchanged
        /// Keys, rotations and cardinals are bound but the dial push is not,
        /// and this firmware is known to refuse AG19 (or writing was not
        /// allowed); nothing written.
        case dialPushUnavailable(found: String?)
        /// Written, and everything reads back bound.
        case applied
        /// Written; everything reads back bound except the dial push, which
        /// the firmware kept as `found`.
        case appliedWithoutDialPush(found: String?)

        public var dialPushBound: Bool {
            switch self {
            case .unchanged, .applied: return true
            case .dialPushUnavailable, .appliedWithoutDialPush: return false
            }
        }

        public var wroteFlash: Bool {
            switch self {
            case .applied, .appliedWithoutDialPush: return true
            case .unchanged, .dialPushUnavailable: return false
            }
        }
    }

    /// Waits around the read-back. A flash write can still be in progress
    /// when `fs.write` answers (or times out), so the first read waits a
    /// moment and a failed check is read again before it counts.
    public struct Timing: Sendable {
        public var settle: TimeInterval
        public var retryDelay: TimeInterval
        /// Reads per verification, the first included.
        public var verifyAttempts: Int

        public init(settle: TimeInterval = 0.75, retryDelay: TimeInterval = 1.0, verifyAttempts: Int = 3) {
            self.settle = settle
            self.retryDelay = retryDelay
            self.verifyAttempts = max(1, verifyAttempts)
        }

        public static let standard = Timing()
        /// For tests.
        public static let immediate = Timing(settle: 0, retryDelay: 0)
    }

    /// One RPC to the pad: method and params in, result out.
    public typealias Call = @MainActor (String, [String: Any]) async throws -> Any?

    // MARK: - Parsing

    /// Unwraps the `{"data": "<json string>"}` envelope.
    public static func parse(_ raw: Any?) throws -> [String: Any] {
        guard let dict = raw as? [String: Any] else {
            throw Failure.unreadable("unexpected response shape")
        }
        guard let inner = dict["data"] as? String,
              let data = inner.data(using: .utf8),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.unreadable("missing or malformed `data` field")
        }
        return config
    }

    /// `layer_index` from `device.status` is 1-based against this list, so the
    /// active layer is the first one.
    /// The array index of the active profile. `activeProfileId` names a
    /// profile's `id`; fall back to treating it as an index, then the first.
    static func activeProfileIndex(_ config: [String: Any], in profiles: [[String: Any]]) -> Int {
        let active = config["activeProfileId"] as? Int ?? 0
        if let byID = profiles.firstIndex(where: { ($0["id"] as? Int) == active }) { return byID }
        return active < profiles.count ? active : 0
    }

    static func activeLayerKeymap(_ config: [String: Any]) -> [[String]]? {
        guard let profiles = config["profiles"] as? [[String: Any]], !profiles.isEmpty else { return nil }
        let profile: [String: Any]? = profiles[activeProfileIndex(config, in: profiles)]
        guard let layers = profile?["layers"] as? [[String: Any]],
              let layer = layers.first,
              let layout = layer["layout"] as? [String: Any],
              let keymap = layout["keymap"] as? [[String]]
        else { return nil }
        return keymap
    }

    static func activeLayerLayout(_ config: [String: Any]) -> [String: Any]? {
        guard let profiles = config["profiles"] as? [[String: Any]], !profiles.isEmpty else { return nil }
        let profile: [String: Any]? = profiles[activeProfileIndex(config, in: profiles)]
        guard let layers = profile?["layers"] as? [[String: Any]],
              let layer = layers.first
        else { return nil }
        return layer["layout"] as? [String: Any]
    }

    /// The input a `KV_OAI_AGnn` keycode reports as: nn.
    static func inputID(for code: String) -> Int {
        OAI.agIndex(code.hasPrefix("KV_OAI_") ? String(code.dropFirst("KV_OAI_".count)) : code) ?? -1
    }

    /// Every managed slot on the active layer that does not carry its AG
    /// code: the keys, the dial (both rotations and the press) and the
    /// joystick's cardinal sectors. A layout with no `encoders` or `joystick`
    /// has nothing to bind there.
    public static func missingBindings(_ config: [String: Any]) -> [MissingBinding] {
        var missing: [MissingBinding] = []
        let keymap = activeLayerKeymap(config)
        for binding in bindings {
            let found: String? = keymap.flatMap { keymap in
                binding.row < keymap.count && binding.column < keymap[binding.row].count
                    ? keymap[binding.row][binding.column] : nil
            }
            if found != binding.code {
                missing.append(MissingBinding(inputID: inputID(for: binding.code),
                                              expected: binding.code, found: found))
            }
        }

        let layout = activeLayerLayout(config)
        if let encoders = layout?["encoders"] as? [[String]], let dial = encoders.first {
            for (index, code) in dialCodes.enumerated() {
                let found = index < dial.count ? dial[index] : nil
                if found != code {
                    missing.append(MissingBinding(inputID: inputID(for: code), expected: code, found: found))
                }
            }
        }
        if let joystick = layout?["joystick"] as? [String: Any],
           let sectors = joystick["sectors"] as? [[String: Any]] {
            for (centre, code) in joystickCodes {
                let sector = sectors.first { sector in
                    guard let a1 = sector["a1"] as? Double, let a2 = sector["a2"] as? Double else { return false }
                    return abs(sectorCentre(a1, a2) - centre) < 0.01
                }
                // A profile set up with fewer directions has no sector there:
                // nothing to bind, and not something a write could fix.
                guard let sector else { continue }
                let found = sector["k"] as? String
                if found != code {
                    missing.append(MissingBinding(inputID: inputID(for: code), expected: code, found: found))
                }
            }
        }
        return missing
    }

    /// Joystick inputs the active profile has no sector for — e.g. a
    /// two-sector layout (up, and one sector for everything else, which
    /// centres on down) has no left or right. Those inputs never report.
    public static func absentJoystickInputs(_ config: [String: Any]) -> [Int] {
        guard let joystick = activeLayerLayout(config)?["joystick"] as? [String: Any],
              let sectors = joystick["sectors"] as? [[String: Any]]
        else { return [] }
        let centres = sectors.compactMap { sector -> Double? in
            guard let a1 = sector["a1"] as? Double, let a2 = sector["a2"] as? Double else { return nil }
            return sectorCentre(a1, a2)
        }
        return joystickCodes
            .filter { pair in !centres.contains { abs($0 - pair.centre) < 0.01 } }
            .compactMap { inputID(for: $0.code) }
            .sorted()
    }

    /// True when every managed key, the dial (both rotations and the press)
    /// and the joystick's cardinal sectors carry their AG codes on the active
    /// layer.
    public static func isAgentKeymapApplied(_ config: [String: Any]) -> Bool {
        missingBindings(config).isEmpty
    }

    /// True when everything but the dial push is bound: the keys light and
    /// every other input reports. AG19 on the press is best-effort.
    public static func isCoreKeymapApplied(_ config: [String: Any]) -> Bool {
        missingBindings(config).allSatisfy(\.isDialPush)
    }

    /// Rebinds the managed keys, the dial and the joystick's cardinals,
    /// leaving every other key, layer, diagonal sector and lighting setting
    /// untouched. Without `includeDialPush` the press slot keeps whatever it
    /// has (stock `KC_MPLY`), for firmware that refuses AG19 there.
    public static func withAgentKeymap(_ config: [String: Any], includeDialPush: Bool = true) throws -> [String: Any] {
        var next = config
        guard var profiles = next["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw Failure.noProfiles
        }
        let profileIndex = activeProfileIndex(next, in: profiles)
        var profile = profiles[profileIndex]
        guard var layers = profile["layers"] as? [[String: Any]], !layers.isEmpty else {
            throw Failure.noProfiles
        }
        var layer = layers[0]
        guard var layout = layer["layout"] as? [String: Any],
              var keymap = layout["keymap"] as? [[String]]
        else { throw Failure.noProfiles }

        for binding in bindings
        where binding.row < keymap.count && binding.column < keymap[binding.row].count {
            keymap[binding.row][binding.column] = binding.code
        }

        // The dial's rotation slots and its press. A layout that lists only
        // the two rotations gains the press slot.
        if var encoders = layout["encoders"] as? [[String]],
           var dial = encoders.first, dial.count >= 2 {
            for (index, code) in dialCodes.prefix(includeDialPush ? dialCodes.count : 2).enumerated() {
                if index < dial.count { dial[index] = code } else { dial.append(code) }
            }
            encoders[0] = dial
            layout["encoders"] = encoders
        }

        // The joystick's cardinal sectors; diagonals keep their keycodes.
        if var joystick = layout["joystick"] as? [String: Any],
           var sectors = joystick["sectors"] as? [[String: Any]] {
            for index in sectors.indices {
                guard let a1 = sectors[index]["a1"] as? Double,
                      let a2 = sectors[index]["a2"] as? Double
                else { continue }
                let centre = sectorCentre(a1, a2)
                if let match = joystickCodes.first(where: { abs($0.centre - centre) < 0.01 }) {
                    sectors[index]["k"] = match.code
                }
            }
            joystick["sectors"] = sectors
            layout["joystick"] = joystick
        }

        layout["keymap"] = keymap
        layer["layout"] = layout
        layers[0] = layer
        profile["layers"] = layers
        profiles[profileIndex] = profile
        next["profiles"] = profiles
        return next
    }

    // MARK: - Device I/O

    @MainActor
    public static func read(_ device: WLDevice) async throws -> [String: Any] {
        try await read(call: { method, params in try await device.callAsync(method, params: params) })
    }

    @MainActor
    static func read(call: Call) async throws -> [String: Any] {
        let raw = try await call("fs.read", ["file": "keymap.json"])
        return try parse(raw)
    }

    /// Reads the keymap and, when something is missing and `mayWrite`,
    /// writes it — at most twice — then reads it back.
    ///
    /// - The first write carries everything, AG19 on the dial push
    ///   included, unless `dialPushRejected` says this firmware refuses it.
    /// - If the keys, rotations or cardinals still do not read back, one
    ///   fallback write without AG19 follows, on top of what the pad has now.
    /// - A write the pad never answered is not a failure by itself: the
    ///   read-back decides.
    ///
    /// Throws `.notAccepted` when the core bindings will not stick (or
    /// cannot be written), `.unconfirmed` when neither the write nor any
    /// read-back was answered.
    @MainActor
    public static func apply(
        _ device: WLDevice,
        dialPushRejected: Bool = false,
        mayWrite: Bool = true,
        timing: Timing = .standard,
        inspect: (([String: Any]) -> Void)? = nil
    ) async throws -> Outcome {
        try await apply(dialPushRejected: dialPushRejected, mayWrite: mayWrite, timing: timing) { method, params in
            let result = try await device.callAsync(method, params: params)
            // Every keymap read passes through here: let the caller see the
            // layout the pad actually has (e.g. which joystick sectors exist).
            if method == "fs.read", let inspect, let config = try? parse(result) { inspect(config) }
            return result
        }
    }

    @MainActor
    static func apply(
        dialPushRejected: Bool,
        mayWrite: Bool,
        timing: Timing,
        call: Call
    ) async throws -> Outcome {
        let config = try await read(call: call)
        let missing = missingBindings(config)
        if missing.isEmpty { return .unchanged }
        let coreMissing = missing.filter { !$0.isDialPush }
        let push = missing.first(where: \.isDialPush)

        if coreMissing.isEmpty, dialPushRejected || !mayWrite {
            return .dialPushUnavailable(found: push?.found)
        }
        guard mayWrite else { throw Failure.notAccepted(missing: missing) }

        let first = try await writeAndVerify(
            try withAgentKeymap(config, includeDialPush: !dialPushRejected),
            expectDialPush: !dialPushRejected, timing: timing, call: call
        )
        if first.missing.isEmpty { return .applied }
        if first.missing.allSatisfy(\.isDialPush) {
            return .appliedWithoutDialPush(found: first.missing.first?.found)
        }
        // Keys, rotations or cardinals did not stick. If AG19 was in that
        // write the firmware may have refused the whole file over it, so try
        // once more without it; otherwise there is nothing different to try.
        guard !dialPushRejected else { throw Failure.notAccepted(missing: first.missing) }
        let second = try await writeAndVerify(
            try withAgentKeymap(first.config, includeDialPush: false),
            expectDialPush: false, timing: timing, call: call
        )
        if second.missing.isEmpty { return .applied }
        if second.missing.allSatisfy(\.isDialPush) {
            return .appliedWithoutDialPush(found: second.missing.first?.found)
        }
        throw Failure.notAccepted(missing: second.missing)
    }

    /// One `fs.write`, then up to `timing.verifyAttempts` reads until what
    /// was written reads back. Returns the last keymap read and what it is
    /// still missing.
    @MainActor
    private static func writeAndVerify(
        _ next: [String: Any],
        expectDialPush: Bool,
        timing: Timing,
        call: Call
    ) async throws -> (config: [String: Any], missing: [MissingBinding]) {
        let encoded = try JSONSerialization.data(withJSONObject: next)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw Failure.unreadable("could not encode keymap")
        }
        var writeTimedOut = false
        var writeError: Error?
        do {
            _ = try await call("fs.write", ["file": "keymap.json", "data": text])
        } catch let failure as WLDevice.Failure where failure.isTimeout {
            // The pad may still be writing flash; the read-back decides.
            writeTimedOut = true
        } catch {
            // An RPC error or a dropped link: the pad may or may not have
            // saved part of it, so the read-back still decides.
            writeError = error
        }

        var last: (config: [String: Any], missing: [MissingBinding])?
        var readError: Error?
        for attempt in 0..<timing.verifyAttempts {
            await pause(attempt == 0 ? timing.settle : timing.retryDelay)
            do {
                let config = try await read(call: call)
                let missing = missingBindings(config)
                last = (config, missing)
                let outstanding = missing.filter { expectDialPush || !$0.isDialPush }
                if outstanding.isEmpty { break }
            } catch {
                readError = error
                // A pad that answers neither the write nor a read is gone
                // for now; waiting out more read timeouts will not help.
                if let failure = error as? WLDevice.Failure, failure.isTimeout { break }
            }
        }
        if let last { return last }
        // A write was attempted and nothing could confirm it: report it as
        // such (never as a plain read error) so callers stop writing.
        if let writeError, !writeTimedOut { throw Failure.writeFailed(writeError.localizedDescription) }
        _ = readError
        throw Failure.unconfirmed
    }

    @MainActor
    private static func pause(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// What the Studio has learnt about one firmware's keymap handling, kept on
/// the host (UserDefaults) and never on the pad: whether it refuses AG19 on
/// the dial push, and whether it refused the bindings outright. Either one
/// stops the Studio rewriting flash on every launch and reconnect until the
/// user asks it to retry.
public struct KeymapRecords {
    private let defaults: UserDefaults
    private static let dialPushPrefix = "keymap.dialPushRejected."
    private static let notAcceptedPrefix = "keymap.notAccepted."

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static let standard = KeymapRecords()

    private static func key(_ prefix: String, _ firmware: String) -> String {
        prefix + (firmware.isEmpty ? "unknown" : firmware)
    }

    public func dialPushRejected(firmware: String) -> Bool {
        defaults.bool(forKey: Self.key(Self.dialPushPrefix, firmware))
    }

    public func setDialPushRejected(_ rejected: Bool, firmware: String) {
        let key = Self.key(Self.dialPushPrefix, firmware)
        if rejected { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public func notAccepted(firmware: String) -> Bool {
        defaults.bool(forKey: Self.key(Self.notAcceptedPrefix, firmware))
    }

    public func setNotAccepted(_ rejected: Bool, firmware: String) {
        let key = Self.key(Self.notAcceptedPrefix, firmware)
        if rejected { defaults.set(true, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Whether any firmware version is on record, for when this connection
    /// could not read the version and the per-version key is unknown.
    public func anyDialPushRejected() -> Bool { hasAny(Self.dialPushPrefix) }
    public func anyNotAccepted() -> Bool { hasAny(Self.notAcceptedPrefix) }

    private func hasAny(_ prefix: String) -> Bool {
        defaults.dictionaryRepresentation().contains { $0.key.hasPrefix(prefix) && ($0.value as? Bool) == true }
    }

    /// Forgets both, for "Retry".
    public func clear(firmware: String) {
        setDialPushRejected(false, firmware: firmware)
        setNotAccepted(false, firmware: firmware)
    }
}
