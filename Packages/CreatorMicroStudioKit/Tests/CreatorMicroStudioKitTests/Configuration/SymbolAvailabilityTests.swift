import AppKit
import XCTest
@testable import CreatorMicroStudioKit

/// Every SF Symbol the package hands the UI must exist on the macOS 13
/// deployment target. A missing name draws nothing and only logs at runtime,
/// so neither the build nor a newer test Mac would otherwise notice.
final class SymbolAvailabilityTests: XCTestCase {

    private var symbols: [String] {
        var names = InputAction.Kind.allCases.map(\.symbol)
        names += InputAction.Category.allCases.map(\.symbol)
        names += InputAction.Direction.allCases.map(\.symbol)
        names += InputAction.MediaKey.allCases.map(\.symbol)
        names += Pad.InputGroup.allCases.map(\.symbol)
        names += Pad.inputs.map(\.symbol)
        return Array(Set(names)).sorted()
    }

    /// Resolves on this Mac. This runs on whatever macOS the tests run on,
    /// usually newer than 13, so it is necessary but not sufficient.
    func testEverySymbolResolves() {
        for name in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "no SF Symbol named \(name)")
        }
    }

    /// Names known to need macOS 14 or later (SF Symbols 5, 2023+). Keep
    /// adding to this when a newer name is replaced.
    private static let tooNew: Set<String> = [
        "gauge.with.dots.needle.0percent",
        "gauge.with.dots.needle.33percent",
        "gauge.with.dots.needle.50percent",
        "gauge.with.dots.needle.67percent",
        "gauge.with.dots.needle.100percent",
        "gauge.with.dots.needle.bottom.0percent",
        "gauge.with.dots.needle.bottom.50percent",
        "gauge.with.dots.needle.bottom.100percent",
    ]

    func testNoSymbolNeedsANewerMacOSThan13() throws {
        for name in symbols {
            XCTAssertFalse(Self.tooNew.contains(name), "\(name) needs macOS 14+")
        }

        // When the system's symbol availability table is present, check
        // every name against it too: the year a symbol first shipped maps to
        // the macOS release that has it.
        let table = "/System/Library/PrivateFrameworks/SFSymbols.framework/Versions/A/Resources/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
        guard let data = FileManager.default.contents(atPath: table),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let years = plist["symbols"] as? [String: String],
              let releases = plist["year_to_release"] as? [String: [String: String]]
        else { return }
        for name in symbols {
            guard let year = years[name], let macOS = releases[year]?["macOS"] else { continue }
            let major = Int(macOS.split(separator: ".").first ?? "") ?? 0
            XCTAssertLessThanOrEqual(major, 13, "\(name) first shipped in macOS \(macOS)")
        }
    }
}
