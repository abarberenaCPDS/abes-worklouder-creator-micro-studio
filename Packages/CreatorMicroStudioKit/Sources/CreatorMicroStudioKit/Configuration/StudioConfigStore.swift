import Foundation

/// The one host-side config file, `config.json`, shared by key bindings and
/// lighting — and by the standalone Inspector, which writes the same file.
///
/// Path: `$XDG_CONFIG_HOME/creator-micro-studio/config.json`, or
/// `~/.config/creator-micro-studio/config.json`. While that file does not exist
/// yet, reads fall back to the pre-rename `micromanager/config.json`; the first
/// write lands at the new path, which migrates it. The legacy file is never
/// deleted.
///
/// Every edit is an atomic read-modify-write that keeps top-level keys this
/// app does not know about, so hand-written or newer config survives a save.
public struct StudioConfigStore: Sendable, Equatable {

    /// Where the file is read from and written to.
    public let path: String
    /// Read only while `path` does not exist.
    public let legacyPath: String?

    public init(path: String, legacyPath: String? = nil) {
        self.path = path
        self.legacyPath = legacyPath
    }

    /// The user's real config file.
    public static var standard: StudioConfigStore {
        let base = configBasePath()
        return StudioConfigStore(
            path: (base as NSString).appendingPathComponent("creator-micro-studio/config.json"),
            legacyPath: (base as NSString).appendingPathComponent("micromanager/config.json")
        )
    }

    /// `$XDG_CONFIG_HOME` when set and not empty, else `~/.config`.
    public static func configBasePath() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
    }

    public enum Failure: LocalizedError, Equatable {
        case malformedConfig(String)

        public var errorDescription: String? {
            switch self {
            case .malformedConfig(let path):
                return "The existing config at \(path) is not a valid JSON object. Fix it before saving."
            }
        }
    }

    /// Whichever file reads would use right now, or nil when neither exists.
    public var effectivePath: String? {
        let manager = FileManager.default
        if manager.fileExists(atPath: path) { return path }
        if let legacyPath, manager.fileExists(atPath: legacyPath) { return legacyPath }
        return nil
    }

    /// The raw bytes, from `path` or, failing that, `legacyPath`.
    public func readData() -> Data? {
        let manager = FileManager.default
        if let data = manager.contents(atPath: path) { return data }
        if let legacyPath { return manager.contents(atPath: legacyPath) }
        return nil
    }

    /// The parsed top-level object; empty when there is no file. Throws when
    /// a file exists but is not a JSON object, so a save never replaces a
    /// file the user is in the middle of fixing.
    public func readObject() throws -> [String: Any] {
        guard let data = readData() else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.malformedConfig(effectivePath ?? path)
        }
        return json
    }

    /// Atomic read-modify-write. `body` gets the whole file; keys it leaves
    /// alone are written back untouched. Edits from this process are
    /// serialised with an in-process lock, and edits from other processes
    /// (the Studio and the standalone Inspector) with an advisory `flock` on
    /// `lockPath`, so two read-modify-writes can never interleave.
    public func update(_ body: (inout [String: Any]) throws -> Void) throws {
        StudioConfigStore.lock.lock()
        defer { StudioConfigStore.lock.unlock() }
        let fileLock = try acquireFileLock()
        defer { releaseFileLock(fileLock) }
        var json = try readObject()
        try body(&json)
        try write(json)
    }

    /// The sidecar advisory lock file next to `path`. Never holds data; the
    /// atomic write replaces `config.json` itself, so the lock cannot live on
    /// that file's inode.
    public var lockPath: String { path + ".lock" }

    private func acquireFileLock() throws -> Int32 {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockPath])
        }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    private func releaseFileLock(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    private func write(_ json: [String: Any]) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static let lock = NSLock()
}
