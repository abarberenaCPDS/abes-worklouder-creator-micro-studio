import XCTest
@testable import CreatorMicroStudioKit

final class StudioConfigStoreTests: XCTestCase {

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wl-store-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testStandardPathsUseTheStudioAndLegacyFolders() {
        let store = StudioConfigStore.standard
        XCTAssertTrue(store.path.hasSuffix("/creator-micro-studio/config.json"))
        XCTAssertEqual(store.legacyPath.map { ($0 as NSString).lastPathComponent }, "config.json")
        XCTAssertTrue(store.legacyPath?.contains("/micromanager/") == true)
        XCTAssertEqual(KeyBindings.configPath(), store.path)
    }

    func testMissingFileReadsAsEmpty() throws {
        let root = directory()
        let store = StudioConfigStore(path: root.appendingPathComponent("a/config.json").path)
        XCTAssertNil(store.readData())
        XCTAssertNil(store.effectivePath)
        XCTAssertTrue(try store.readObject().isEmpty)
    }

    /// Until the new file exists, the old micromanager config is read; the
    /// first save lands at the new path and keeps what the old one had.
    func testLegacyFileIsReadThenMigratedOnFirstWrite() throws {
        let root = directory()
        let legacy = root.appendingPathComponent("micromanager/config.json").path
        let current = root.appendingPathComponent("creator-micro-studio/config.json").path
        try write(#"{"keys": {"9": "old macro"}, "actions": {"9": "macro"}}"#, to: legacy)
        let store = StudioConfigStore(path: current, legacyPath: legacy)

        XCTAssertEqual(store.effectivePath, legacy)
        XCTAssertEqual(KeyBindings.load(from: store).action(for: 9), .insertText("old macro"))

        try KeyBindings.setAction(.zoomPane, for: 6, store: store)
        XCTAssertEqual(store.effectivePath, current)
        let loaded = KeyBindings.load(from: store)
        XCTAssertEqual(loaded.action(for: 9), .insertText("old macro"))
        XCTAssertEqual(loaded.action(for: 6), .zoomPane)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy), "the legacy file is never deleted")
    }

    func testUpdateKeepsUnknownKeysAndIsAtomic() throws {
        let root = directory()
        let store = StudioConfigStore(path: root.appendingPathComponent("config.json").path)
        try write(#"{"mystery": [1, 2, 3], "nested": {"a": true}}"#, to: store.path)
        try store.update { $0["added"] = "yes" }
        let json = try store.readObject()
        XCTAssertEqual(json["mystery"] as? [Int], [1, 2, 3])
        XCTAssertEqual((json["nested"] as? [String: Any])?["a"] as? Bool, true)
        XCTAssertEqual(json["added"] as? String, "yes")
    }

    func testMalformedFileThrowsAndIsLeftAlone() throws {
        let root = directory()
        let store = StudioConfigStore(path: root.appendingPathComponent("config.json").path)
        try write("[1, 2]", to: store.path)
        XCTAssertThrowsError(try store.update { $0["x"] = 1 }) { error in
            XCTAssertEqual(error as? StudioConfigStore.Failure, .malformedConfig(store.path))
        }
        XCTAssertEqual(try String(contentsOfFile: store.path), "[1, 2]")
    }

    func testBlankFileCountsAsEmpty() throws {
        let root = directory()
        let store = StudioConfigStore(path: root.appendingPathComponent("config.json").path)
        try write("  \n", to: store.path)
        XCTAssertNoThrow(try store.update { $0["x"] = 1 })
        XCTAssertEqual(try store.readObject()["x"] as? Int, 1)
    }

    /// Writes take an advisory flock on a sidecar file next to config.json,
    /// so another process (the standalone Inspector) holding it blocks them.
    func testUpdateTakesTheSidecarFileLock() throws {
        let root = directory()
        let store = StudioConfigStore(path: root.appendingPathComponent("config.json").path)
        XCTAssertEqual(store.lockPath, store.path + ".lock")
        try store.update { $0["a"] = 1 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.lockPath))

        // Hold the lock as another process would (flock is per open file).
        let fd = open(store.lockPath, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let finished = expectation(description: "update finished")
        let order = OrderLog()
        DispatchQueue.global().async {
            try? store.update { $0["b"] = 2 }
            order.append("update")
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        order.append("unlock")
        flock(fd, LOCK_UN)
        close(fd)
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(order.entries, ["unlock", "update"])
        let json = try store.readObject()
        XCTAssertEqual(json["a"] as? Int, 1)
        XCTAssertEqual(json["b"] as? Int, 2)
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
