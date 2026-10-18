import Foundation
import CoreGraphics
import IOKit
import IOKit.hid

/// Raw-HID JSON-RPC transport for Work Louder devices.
///
/// Framing, on 64-byte reports carried by the vendor collection
/// (usage page 0xFF00 / usage 1):
///
///     byte 0      report id, always 0x06
///     byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
///     byte 2      payload length in this report, max 61
///     bytes 3..   UTF-8 fragment of the JSON message
///
/// Messages are split across as many reports as needed and reassembled by
/// scanning for balanced top-level braces.
///
/// The device must be opened **non-exclusively**. Its vendor collection shares
/// an IOHIDDevice with a keyboard collection, and macOS refuses to let anything
/// seize a keyboard — a seizing open fails with 0xE00002C1, which looks exactly
/// like a missing Input Monitoring grant and is not.
public final class WLDevice {

    public static let vendorID = 0x303A
    public static let reportID: UInt8 = 0x06
    public static let channelDebug: UInt8 = 1
    public static let channelRPC: UInt8 = 2
    public static let maxChunk = 61
    public static let reportSize = 64

    public struct Info {
        public var product: String
        public var productID: Int
        public var transport: String
        public var serial: String
        public var usagePage: Int
        public var interfaceCount: Int
    }

    public static let vendorUsagePage = 0xFF00
    public static let vendorUsage = 0x01

    public enum Failure: LocalizedError {
        case notFound
        case noVendorCollection
        case openFailed(IOReturn)
        case notConnected
        case writeFailed(IOReturn)
        case timeout(String)
        case rpc(String, String)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Work Louder device on the HID bus. If it is a Bluetooth pad it may have gone to sleep — press a key to wake it."
            case .noVendorCollection:
                return "Found the device, but not its vendor collection (usage page 0xFF00). Nothing to talk to."
            case .openFailed(let r):
                let code = UInt32(bitPattern: r)
                if r == kIOReturnNotPermitted || code == 0xE00002E2 {
                    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? "this app"
                    return String(format: "HID access denied (0x%08X). Grant Input Monitoring to %@ in System Settings → Privacy & Security → Input Monitoring, then try Connect again.", code, appName)
                }
                if r == kIOReturnNotPrivileged || UInt32(bitPattern: r) == 0xE00002C1 {
                    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? "this app"
                    return "Open refused (0xE00002C1). Grant Input Monitoring to \(appName) in System Settings → Privacy & Security → Input Monitoring, then try Connect again."
                }
                return String(format: "IOHIDDeviceOpen failed (0x%08X)", code)
            case .notConnected:
                return "Not connected."
            case .writeFailed(let r):
                let code = UInt32(bitPattern: r)
                let name: String
                switch code {
                case 0xE00002CD: name = " — kIOReturnNotOpen, the device handle is no longer open"
                case 0xE00002C0: name = " — kIOReturnNoDevice"
                case 0xE00002C5: name = " — kIOReturnExclusiveAccess"
                case 0xE00002C1: name = " — kIOReturnNotPrivileged"
                case 0xE00002C7: name = " — kIOReturnUnsupported, wrong report id or interface"
                default: name = ""
                }
                return String(format: "IOHIDDeviceSetReport failed (0x%08X)", code) + name
            case .timeout(let m):
                return "Timed out waiting for \(m)."
            case .rpc(let method, let message):
                return "\(method): \(message)"
            }
        }
    }

    // Callbacks, always delivered on the main queue.
    public var onTX: ((String, Any?, Int) -> Void)?          // method, params, id
    public var onResponse: ((Int, Any?, String?) -> Void)?   // id, result, errorMessage
    public var onNotification: ((String, Any?) -> Void)?     // method, params
    public var onDeviceLog: ((String) -> Void)?
    public var onWriteError: ((String, String) -> Void)?
    /// Every input report, before framing. Reports that do not match the
    /// channel framing are otherwise dropped, which hides any other traffic
    /// the device emits - key presses included.
    public var onRawReport: ((UInt32, [UInt8]) -> Void)?
    public var onDisconnect: ((String) -> Void)?

    public private(set) var info: Info?
    /// When set, every call is answered by this instead of by the HID bus, and
    /// nothing touches IOKit. See `PadEmulator`.
    public let emulator: PadEmulator?
    private var emulatedConnected = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
    private var rpcAccumulator = ""
    private var debugAccumulator = ""
    /// Waiting completions by call id. The token tells a call apart from a
    /// later one that reused its id (ids wrap below 1000), so a stale timer
    /// can never fail the wrong call.
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var nextToken = 1

    private struct Pending {
        let token: Int
        let done: (Any?, String?) -> Void
    }

    /// How long the firmware gets to answer once a message has been sent,
    /// unless a call says otherwise. `fs.write` makes it parse the file and
    /// write flash; `fs.read` returns a few KB over ~45 reports.
    public static func defaultTimeout(for method: String) -> TimeInterval {
        switch method {
        case "fs.write": return 30
        case "fs.read": return 15
        default: return 8
        }
    }

    /// The outer cap's allowance per report still to be written — this
    /// call's and any queued ahead of it. Over Bluetooth LE each
    /// `IOHIDDeviceSetReport` waits for an acknowledgement (15–60 ms, more
    /// when the pad has just woken), so this is generous on purpose: it only
    /// exists so a wedged write queue still fails the call.
    var perReportAllowance: TimeInterval = 0.5
    /// Reports queued on `writeQueue` and not yet attempted. Main only.
    private var queuedReports = 0

    /// Writes one 64-byte output report. Runs on `writeQueue`, never main.
    typealias ReportWriter = ([UInt8]) -> IOReturn
    /// Set while a hardware (or test) connection is open.
    private var writer: ReportWriter?
    /// `IOHIDDeviceSetReport` blocks until the report is on the wire, which
    /// over Bluetooth LE is milliseconds per report — and a full paint is
    /// 15–20 of them. Every write goes through this serial queue so the main
    /// thread never waits on the radio, and messages stay in call order.
    private let writeQueue = DispatchQueue(label: "dev.abeisonai.worklouder.hid-write", qos: .userInitiated)
    /// Bumped on every connect and disconnect. Writes queued for an earlier
    /// connection are skipped, and their failures are not reported.
    private let writeGate = WriteGate()

    public var isConnected: Bool { writer != nil || emulatedConnected }

    public init(emulator: PadEmulator? = nil) { self.emulator = emulator }

    /// What macOS has recorded for this app's Input Monitoring grant.
    public enum InputMonitoringAccess: Equatable {
        case granted
        /// No decision yet: requesting shows the system "Keystroke Receiving" sheet.
        case undetermined
        /// Denied, or recorded for an earlier build's signature. macOS will not
        /// show its sheet again until the record is reset or changed in Settings.
        case denied
    }

    public static var inputMonitoringAccess: InputMonitoringAccess {
        if hasInputMonitoringAccess { return .granted }
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeDenied
            ? .denied : .undetermined
    }

    /// Whether this process has the Input Monitoring grant needed for HID input.
    public static var hasInputMonitoringAccess: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            || CGPreflightListenEventAccess()
    }

    /// Explicitly ask macOS for Input Monitoring before opening real HID.
    /// CGRequestListenEventAccess presents the system authorization sheet when
    /// macOS can still request consent; IOHIDRequestAccess covers HID clients.
    /// Previously denied grants still need to be changed in System Settings.
    @discardableResult
    public static func requestInputMonitoringAccessIfNeeded() -> Bool {
        guard !hasInputMonitoringAccess else { return true }
        _ = CGRequestListenEventAccess()
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        return hasInputMonitoringAccess
    }

    deinit { inputBuffer.deallocate() }

    // MARK: - Connect

    public func connect() throws {
        disconnect(reason: nil)

        if let emulator {
            emulatedConnected = true
            info = Info(
                product: "Creator Micro 2 (emulated)",
                productID: 0x8297,
                transport: "emulated",
                serial: "EMULATOR",
                usagePage: WLDevice.vendorUsagePage,
                interfaceCount: 1
            )
            emulator.onNotify = { [weak self] method, params in
                guard let self else { return }
                DispatchQueue.main.async { self.onNotification?(method, params) }
            }
            return
        }

        // Must be held for the lifetime of the connection: releasing the
        // manager tears down the devices it opened, and every later SetReport
        // then fails with kIOReturnNotOpen.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        // Match on vendor only: over Bluetooth the pad presents a single
        // IOHIDDevice whose *primary* usage is keyboard, with the vendor
        // collection alongside it in DeviceUsagePairs.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WLDevice.vendorID] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            throw Failure.notFound
        }
        // Over Bluetooth the pad is a single IOHIDDevice whose primary usage is
        // keyboard, with the vendor collection alongside it in DeviceUsagePairs.
        // Over USB each interface is its own IOHIDDevice, so picking the first
        // match lands on the keyboard and every report id 6 write is dropped.
        // Select the one that actually carries the vendor collection.
        guard let dev = set.first(where: { primaryUsagePage($0) == WLDevice.vendorUsagePage })
            ?? set.first(where: { hasVendorCollection($0) })
        else {
            throw Failure.noVendorCollection
        }

        let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw Failure.openFailed(result) }

        device = dev
        writeGate.advance()
        writer = { report in
            report.withUnsafeBufferPointer { buf in
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(WLDevice.reportID), buf.baseAddress!, buf.count)
            }
        }
        info = Info(
            product: string(dev, kIOHIDProductKey) ?? "Work Louder device",
            productID: number(dev, kIOHIDProductIDKey) ?? 0,
            transport: string(dev, kIOHIDTransportKey) ?? "?",
            serial: string(dev, kIOHIDSerialNumberKey) ?? "",
            usagePage: primaryUsagePage(dev) ?? 0,
            interfaceCount: set.count
        )

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, WLDevice.reportSize, { ctx, _, _, _, reportID, report, length in
            guard let ctx, length > 0 else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            let bytes = Array(UnsafeBufferPointer(start: report, count: Int(length)))
            DispatchQueue.main.async { me.handleReport(bytes, reportID: reportID) }
        }, context)

        IOHIDDeviceRegisterRemovalCallback(dev, { ctx, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<WLDevice>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.disconnect(reason: "device removed") }
        }, context)

        // Common modes, not just the default one: while a menu or a modal
        // sheet is up the main run loop runs in event-tracking mode, and
        // replies (and key presses) parked until it closes would let the
        // reply timers — which run in common modes — fire on answers that had
        // already arrived.
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    public func disconnect(reason: String?) {
        if emulator != nil {
            guard emulatedConnected else { return }
            emulatedConnected = false
            emulator?.onNotify = nil
            info = nil
            failAllPending("disconnected")
            if let reason { onDisconnect?(reason) }
            return
        }
        guard writer != nil else { return }
        // Messages not yet started for this connection are dropped from here
        // on; one already being written is finished (see `call`).
        writeGate.advance()
        writer = nil
        let dev = device
        let mgr = manager
        device = nil
        manager = nil
        if let dev {
            IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        // Close behind the queued writes, so a report already inside
        // IOHIDDeviceSetReport never races the close of its device.
        if dev != nil || mgr != nil {
            writeQueue.async {
                if let dev { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
                if let mgr { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
            }
        }
        info = nil
        rpcAccumulator = ""
        debugAccumulator = ""
        queuedReports = 0
        failAllPending("disconnected")
        if let reason { onDisconnect?(reason) }
    }

    private func failAllPending(_ message: String) {
        let waiting = pending.values.sorted { $0.token < $1.token }
        pending.removeAll()
        for entry in waiting { entry.done(nil, message) }
    }

    /// Removes and returns the completion for `id`, only if it still
    /// belongs to the call that issued `token`.
    private func takePending(_ id: Int, token: Int) -> ((Any?, String?) -> Void)? {
        guard let entry = pending[id], entry.token == token else { return nil }
        pending.removeValue(forKey: id)
        return entry.done
    }

    // MARK: - Send

    /// Sends one JSON-RPC message.
    ///
    /// `timeout` (default `defaultTimeout(for:)`) counts from when the
    /// message's last report has been written, not from when it was queued:
    /// over Bluetooth LE a ~45-report `fs.write` can take seconds just to
    /// send, and that must not eat the firmware's time to parse, write flash
    /// and reply. A separate outer cap, armed at queue time, still fails the
    /// call if the write queue itself never gets to it.
    @discardableResult
    public func call(
        _ method: String,
        params: Any?,
        timeout: TimeInterval? = nil,
        completion: ((Any?, String?) -> Void)? = nil
    ) -> Int? {
        guard emulatedConnected || writer != nil else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        // Firmware only accepts call ids below 1000.
        let id = nextID
        nextID = nextID % 998 + 1

        if let emulator {
            onTX?(method, params, id)
            // Answer on the next turn of the run loop rather than inline: a
            // real call is never synchronous, and callers that assume it is
            // would work here and deadlock on hardware.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let (result, error) = emulator.handle(method, params: params)
                self.onResponse?(id, result, error)
                completion?(result, error)
            }
            return id
        }

        guard let writer else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        var message: [String: Any] = ["method": method, "id": id]
        message["params"] = params ?? NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            completion?(nil, "could not encode params")
            return nil
        }

        let reports = WLDevice.reports(for: [UInt8](data))
        let replyTimeout = timeout ?? WLDevice.defaultTimeout(for: method)
        let token = nextToken
        nextToken &+= 1
        let timeoutText = Failure.timeout(method).errorDescription

        // Registered before the write is even queued: the reply is handled on
        // main, so it can never overtake this, and the contention check in
        // the bridge needs the id issued before any answer arrives. A reply
        // that lands before the reply timer is armed simply finds nothing to
        // arm it for.
        onTX?(method, params, id)
        if let completion {
            pending[id] = Pending(token: token, done: completion)
            let backlog = queuedReports + reports.count
            let cap = replyTimeout + Double(backlog) * perReportAllowance
            DispatchQueue.main.asyncAfter(deadline: .now() + cap) { [weak self] in
                guard let self, let waiting = self.takePending(id, token: token) else { return }
                waiting(nil, timeoutText)
            }
        }
        queuedReports += reports.count

        let generation = writeGate.current
        let gate = writeGate
        let count = reports.count
        writeQueue.async { [weak self] in
            // Disconnected (or reconnected) since this was queued: the
            // pending completion has already been told. Checked once per
            // message, never between its reports: half a JSON object would
            // leave the firmware's brace scanner unbalanced and swallow the
            // next connection's first message.
            guard gate.current == generation else { return }
            for report in reports {
                let rc = writer(report)
                guard rc == kIOReturnSuccess else {
                    // Surface the failure rather than dropping it: a silent
                    // write error is indistinguishable from a device that
                    // ignores you. The rest of this message is not sent.
                    let text = Failure.writeFailed(rc).errorDescription ?? "write failed"
                    DispatchQueue.main.async {
                        guard let self, gate.current == generation else { return }
                        self.queuedReports = max(0, self.queuedReports - count)
                        self.onWriteError?(method, text)
                        if let waiting = self.takePending(id, token: token) { waiting(nil, text) }
                    }
                    return
                }
            }
            // Every report is on the wire: now the firmware's clock starts.
            DispatchQueue.main.async {
                guard let self, gate.current == generation else { return }
                self.queuedReports = max(0, self.queuedReports - count)
                guard self.pending[id]?.token == token else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + replyTimeout) { [weak self] in
                    guard let self, let waiting = self.takePending(id, token: token) else { return }
                    waiting(nil, timeoutText)
                }
            }
        }
        return id
    }

    /// Splits one encoded message into channel-framed 64-byte reports.
    static func reports(for payload: [UInt8]) -> [[UInt8]] {
        var reports: [[UInt8]] = []
        var offset = 0
        while offset < payload.count {
            let n = min(WLDevice.maxChunk, payload.count - offset)
            var report = [UInt8](repeating: 0, count: WLDevice.reportSize)
            report[0] = WLDevice.reportID
            report[1] = WLDevice.channelRPC
            report[2] = UInt8(n)
            report.replaceSubrange(3..<(3 + n), with: payload[offset..<(offset + n)])
            reports.append(report)
            offset += n
        }
        return reports
    }

    /// For tests: behave as a connected hardware device whose reports go to
    /// `writer` (called on the write queue). Responses can be fed with
    /// `receiveForTesting(_:)`.
    func connectForTesting(writer: @escaping ReportWriter) {
        disconnect(reason: nil)
        writeGate.advance()
        self.writer = writer
    }

    /// For tests: hands one input report to the parser, as the HID input
    /// callback would.
    func receiveForTesting(_ bytes: [UInt8]) {
        handleReport(bytes, reportID: UInt32(WLDevice.reportID))
    }

    /// Waits until every write queued so far has been attempted.
    func flushWritesForTesting() {
        writeQueue.sync {}
    }

    // MARK: - Receive

    private func handleReport(_ bytes: [UInt8], reportID: UInt32) {
        onRawReport?(reportID, bytes)
        // The input callback delivers the report id out-of-band, so the
        // payload normally starts at index 0 — but be tolerant of stacks that
        // include it, and try the shifted alignment too.
        if !parse(bytes, at: 0) { _ = parse(bytes, at: 1) }
    }

    private func parse(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard bytes.count > offset + 2 else { return false }
        let channel = bytes[offset]
        let length = Int(bytes[offset + 1])
        guard channel == WLDevice.channelRPC || channel == WLDevice.channelDebug else { return false }
        guard length > 0, length <= WLDevice.maxChunk, bytes.count >= offset + 2 + length else { return false }

        let slice = Array(bytes[(offset + 2)..<(offset + 2 + length)])
        guard let text = String(bytes: slice, encoding: .utf8) else { return false }

        if channel == WLDevice.channelDebug {
            debugAccumulator += text
            while let idx = debugAccumulator.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(debugAccumulator[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                debugAccumulator = String(debugAccumulator[debugAccumulator.index(after: idx)...])
                if !line.isEmpty { onDeviceLog?(line) }
            }
            if debugAccumulator.count > 4096 { debugAccumulator = "" }
            return true
        }

        rpcAccumulator += text
        drainRPC()
        if rpcAccumulator.count > 8192 { rpcAccumulator = "" }
        return true
    }

    /// Pulls complete top-level JSON objects out of the accumulator.
    private func drainRPC() {
        while let object = nextJSONObject() {
            guard
                let data = object.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let id = decoded["id"] as? Int {
                let error = (decoded["error"] as? [String: Any])?["message"] as? String
                let result = decoded["result"]
                onResponse?(id, result, error)
                if let waiting = pending.removeValue(forKey: id) { waiting.done(result, error) }
            } else if let method = (decoded["m"] as? String) ?? (decoded["method"] as? String) {
                // Device-pushed notification. Note the envelope is abbreviated
                // here - {"m": method, "p": params} - while responses use the
                // full "method". Matching only on "method" drops every one.
                let params = decoded["m"] != nil ? decoded["p"] : decoded["params"]
                onNotification?(method, params)
            }
        }
    }

    private func nextJSONObject() -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = rpcAccumulator.startIndex

        while index < rpcAccumulator.endIndex {
            let ch = rpcAccumulator[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        let end = rpcAccumulator.index(after: index)
                        let object = String(rpcAccumulator[s..<end])
                        rpcAccumulator = String(rpcAccumulator[end...])
                        return object
                    }
                }
            }
            index = rpcAccumulator.index(after: index)
        }
        return nil
    }

    // MARK: - Properties

    /// A connection generation readable from the write queue.
    private final class WriteGate: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
        @discardableResult
        func advance() -> Int {
            lock.lock(); defer { lock.unlock() }
            value &+= 1
            return value
        }
    }

    private func string(_ dev: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? String
    }

    private func number(_ dev: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? Int
    }

    private func primaryUsagePage(_ dev: IOHIDDevice) -> Int? {
        number(dev, kIOHIDPrimaryUsagePageKey)
    }

    /// True when this IOHIDDevice exposes the vendor collection, either as its
    /// primary usage or as one of its DeviceUsagePairs.
    private func hasVendorCollection(_ dev: IOHIDDevice) -> Bool {
        if primaryUsagePage(dev) == WLDevice.vendorUsagePage { return true }
        guard let pairs = IOHIDDeviceGetProperty(dev, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]
        else { return false }
        return pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? Int) == WLDevice.vendorUsagePage }
    }
}
