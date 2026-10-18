import XCTest
@testable import CreatorMicroStudioKit

/// Uses a real keymap read off a device, so the double-encoded envelope and the
/// layer layout are exercised against genuine data rather than a fixture I
/// invented to match my own parser. It is the stock F-key map, straight from
/// `fs.read` — keep it that way, because half these tests assert on what an
/// *unmodified* device looks like.
final class KeymapManagerTests: XCTestCase {

    private func backupKeymap() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "stock-keymap",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try KeymapManager.parse(raw)
    }

    func testParsesTheDoubleEncodedEnvelope() throws {
        let config = try backupKeymap()
        XCTAssertNotNil(config["profiles"], "inner JSON string must be decoded")
    }

    func testStockKeymapIsNotAgentBound() throws {
        let config = try backupKeymap()
        XCTAssertFalse(
            KeymapManager.isAgentKeymapApplied(config),
            "the backup is the stock F-key map"
        )
        XCTAssertEqual(KeymapManager.activeLayerKeymap(config)?[0], ["KC_F13", "KC_F14"])
    }

    /// The whole pad is managed now — every key must carry its own AG code,
    /// each key's code matching its index so lights and presses line up.
    func testApplyingBindsEveryKeyToItsOwnCode() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next))

        let keymap = try XCTUnwrap(KeymapManager.activeLayerKeymap(next))
        XCTAssertEqual(Set(Pad.boundKeyIDs).count, Pad.keyCount, "every key is managed")
        for key in Pad.boundKeyIDs {
            let at = try XCTUnwrap(Pad.position(of: key))
            XCTAssertEqual(keymap[at.row][at.column], KeymapManager.agCodes[key])
        }
    }

    /// A pad bound the old way — six agent keys, key 6 still on its F-key —
    /// has to report as *not* applied, or the rebind never happens.
    func testAgentOnlyKeymapIsNotConsideredApplied() throws {
        var config = try backupKeymap()
        var profiles = try XCTUnwrap(config["profiles"] as? [[String: Any]])
        var layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        var layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        var keymap = try XCTUnwrap(layout["keymap"] as? [[String]])
        keymap[0] = ["KV_OAI_AG00", "KV_OAI_AG01"]
        keymap[1] = ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"]
        layout["keymap"] = keymap
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles

        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(try KeymapManager.withAgentKeymap(config)))
    }

    /// The dial's rotations and its press all become AG codes; the press
    /// takes AG19, the last free id.
    func testApplyingBindsTheDialAndItsPress() throws {
        let config = try backupKeymap()
        let original = try XCTUnwrap(KeymapManager.activeLayerLayout(config))
        let originalDial = try XCTUnwrap((original["encoders"] as? [[String]])?.first)
        XCTAssertEqual(originalDial[2], "KC_MPLY", "stock press is play/pause")

        let next = try KeymapManager.withAgentKeymap(config)
        let layout = try XCTUnwrap(KeymapManager.activeLayerLayout(next))
        let dial = try XCTUnwrap((layout["encoders"] as? [[String]])?.first)
        XCTAssertEqual(dial, ["KV_OAI_AG13", "KV_OAI_AG14", "KV_OAI_AG19"])
    }

    /// A pad bound by the previous build — rotations only — must read as not
    /// applied, so it gets exactly one more write to take the press.
    func testPadBoundWithoutThePressNeedsOneMoreWrite() throws {
        var config = try KeymapManager.withAgentKeymap(try backupKeymap())
        config = try replacingDial(in: config, with: ["KV_OAI_AG13", "KV_OAI_AG14", "KC_MPLY"])
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))

        let rebound = try KeymapManager.withAgentKeymap(config)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(rebound))
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(try KeymapManager.withAgentKeymap(rebound)),
                      "and none after that")
    }

    /// An encoder listed with only its two rotations gains the press slot.
    func testTwoSlotEncoderGainsThePress() throws {
        let config = try replacingDial(in: try backupKeymap(), with: ["KC_VOLU", "KC_VOLD"])
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied(config))
        let next = try KeymapManager.withAgentKeymap(config)
        let dial = try XCTUnwrap((KeymapManager.activeLayerLayout(next)?["encoders"] as? [[String]])?.first)
        XCTAssertEqual(dial, ["KV_OAI_AG13", "KV_OAI_AG14", "KV_OAI_AG19"])
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(next))
    }

    private func replacingDial(in config: [String: Any], with dial: [String]) throws -> [String: Any] {
        var config = config
        var profiles = try XCTUnwrap(config["profiles"] as? [[String: Any]])
        var layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        var layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        var encoders = try XCTUnwrap(layout["encoders"] as? [[String]])
        encoders[0] = dial
        layout["encoders"] = encoders
        layers[0]["layout"] = layout
        profiles[0]["layers"] = layers
        config["profiles"] = profiles
        return config
    }

    /// The joystick's four cardinal sectors become AG codes; diagonals keep
    /// whatever they had.
    func testApplyingBindsTheJoystickCardinals() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let layout = try XCTUnwrap(KeymapManager.activeLayerLayout(next))
        let joystick = try XCTUnwrap(layout["joystick"] as? [String: Any])
        let sectors = try XCTUnwrap(joystick["sectors"] as? [[String: Any]])

        var cardinals: [Double: String] = [:]
        var diagonals = 0
        for sector in sectors {
            let a1 = try XCTUnwrap(sector["a1"] as? Double)
            let a2 = try XCTUnwrap(sector["a2"] as? Double)
            let centre = KeymapManager.sectorCentre(a1, a2)
            if let code = sector["k"] as? String, code.hasPrefix("KV_OAI_AG") {
                cardinals[centre] = code
            } else {
                diagonals += 1
            }
        }
        XCTAssertEqual(cardinals[0.25], "KV_OAI_AG15")
        XCTAssertEqual(cardinals[0.50], "KV_OAI_AG16")
        XCTAssertEqual(cardinals[0.75], "KV_OAI_AG17")
        XCTAssertEqual(cardinals[0.00], "KV_OAI_AG18")
        XCTAssertEqual(diagonals, 4, "the diagonal sectors keep their keycodes")
    }

    func testApplyingIsIdempotent() throws {
        let once = try KeymapManager.withAgentKeymap(try backupKeymap())
        let twice = try KeymapManager.withAgentKeymap(once)
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(twice))
    }

    func testEverythingElseSurvivesTheRewrite() throws {
        let config = try backupKeymap()
        let next = try KeymapManager.withAgentKeymap(config)

        let profiles = try XCTUnwrap(next["profiles"] as? [[String: Any]])
        let layers = try XCTUnwrap(profiles[0]["layers"] as? [[String: Any]])
        XCTAssertEqual(layers.count, 3, "the other layers are preserved")

        let layout = try XCTUnwrap(layers[0]["layout"] as? [String: Any])
        XCTAssertNotNil(layout["encoders"], "encoders survive")
        XCTAssertNotNil(layout["joystick"], "joystick survives")
        XCTAssertNotNil(layers[0]["lights"], "per-layer lighting survives")
    }

    func testMalformedInputIsRejectedRatherThanSilentlyAccepted() {
        XCTAssertThrowsError(try KeymapManager.parse(["nope": 1]))
        XCTAssertThrowsError(try KeymapManager.parse(["data": "not json"]))
        XCTAssertFalse(KeymapManager.isAgentKeymapApplied([:]))
    }

    // A pad profile set up in Work Louder's app with a two-sector joystick:
    // up, and one sector covering everything else (it centres on down).
    // Mirrors a real `fs.read` from firmware 0.6.3, where the active profile
    // is found by its `id`.
    private func twoSectorKeymap(dialPush: String = "KV_OAI_AG19") -> [String: Any] {
        let keys = [["KV_OAI_AG00", "KV_OAI_AG01"],
                    ["KV_OAI_AG02", "KV_OAI_AG03", "KV_OAI_AG04", "KV_OAI_AG05"],
                    ["KV_OAI_AG06", "KV_OAI_AG07", "KV_OAI_AG08", "KV_OAI_AG09"],
                    ["KV_OAI_AG10", "KV_OAI_AG11", "KV_OAI_AG12"]]
        func layer(_ push: String) -> [String: Any] {
            ["layout": ["keymap": keys,
                        "joystick": ["type": "RADIAL", "sectors": [
                            ["k": "KV_OAI_AG15", "a1": 0.1875, "a2": 0.3125],
                            ["k": "KV_OAI_AG17", "a1": 0.3125, "a2": 0.1875],
                        ]],
                        "encoders": [["KV_OAI_AG13", "KV_OAI_AG14", push]]]]
        }
        return ["version": 1, "activeProfileId": 7, "profiles": [
            ["id": 0, "layers": [layer("KC_NONE")]],
            ["id": 7, "layers": [layer(dialPush)]],
        ]]
    }

    func testTwoSectorJoystickIsFullyBoundAndReportsAbsentDirections() {
        let config = twoSectorKeymap()
        XCTAssertEqual(KeymapManager.missingBindings(config), [], "absent sectors are not missing bindings")
        XCTAssertTrue(KeymapManager.isAgentKeymapApplied(config))
        XCTAssertEqual(KeymapManager.absentJoystickInputs(config), [Pad.joyWestID, Pad.joyEastID].sorted())
    }

    func testActiveProfileIsFoundByItsID() {
        // Profile id 7 sits at index 1; the dial push there is unbound.
        let missing = KeymapManager.missingBindings(twoSectorKeymap(dialPush: "KC_MPLY"))
        XCTAssertEqual(missing.map(\.inputID), [Pad.dialPushID])
    }

    func testFourSectorStockLayoutHasNoAbsentDirections() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "stock-keymap", withExtension: "json", subdirectory: "Fixtures"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(KeymapManager.absentJoystickInputs(config), [])
    }
}
