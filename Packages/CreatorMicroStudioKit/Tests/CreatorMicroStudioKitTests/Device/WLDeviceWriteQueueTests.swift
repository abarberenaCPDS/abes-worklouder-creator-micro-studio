import XCTest
import IOKit
@testable import CreatorMicroStudioKit

/// HID writes run on a serial queue off the main thread. A test writer
/// stands in for `IOHIDDeviceSetReport`; nothing touches IOKit.
@MainActor
final class WLDeviceWriteQueueTests: XCTestCase {

    /// Reports written, with whether each was written on the main thread.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(report: [UInt8], onMain: Bool)] = []
        var failAt: Int?
        var gate: DispatchSemaphore?

        private var entered = 0

        /// Writes that have started (possibly still blocked on `gate`).
        var pendingWriters: Int {
            lock.lock(); defer { lock.unlock() }
            return entered
        }

        func write(_ report: [UInt8]) -> IOReturn {
            lock.lock(); entered += 1; lock.unlock()
            gate?.wait()
            lock.lock(); defer { lock.unlock() }
            stored.append((report, Thread.isMainThread))
            if let failAt, stored.count == failAt { return kIOReturnNotOpen }
            return kIOReturnSuccess
        }

        var reports: [(report: [UInt8], onMain: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return stored
        }

        /// The JSON messages, reassembled from the written reports.
        var messages: [[String: Any]] {
            var text = ""
            for (report, _) in reports {
                let length = Int(report[2])
                text += String(decoding: report[3..<(3 + length)], as: UTF8.self)
            }
            var result: [[String: Any]] = []
            var depth = 0
            var current = ""
            for ch in text {
                current.append(ch)
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        if let object = try? JSONSerialization.jsonObject(with: Data(current.utf8)) as? [String: Any] {
                            result.append(object)
                        }
                        current = ""
                    }
                }
            }
            return result
        }
    }

    private func response(id: Int) -> [UInt8] {
        let payload = [UInt8](#"{"id":\#(id),"result":{"ok":1}}"#.utf8)
        return [WLDevice.channelRPC, UInt8(payload.count)] + payload
    }

    /// Lets queued main-queue blocks run.
    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testReportsAreFramedAndSplit() {
        let payload = [UInt8](repeating: 0x41, count: 130)
        let reports = WLDevice.reports(for: payload)
        XCTAssertEqual(reports.map { Int($0[2]) }, [61, 61, 8])
        XCTAssertTrue(reports.allSatisfy { $0.count == WLDevice.reportSize && $0[0] == WLDevice.reportID && $0[1] == WLDevice.channelRPC })
    }

    func testWritesHappenOffMainInCallOrder() async {
        let recorder = Recorder()
        let device = WLDevice()
        device.connectForTesting(writer: recorder.write)
        let big = Array(repeating: ["k": 1, "color": 0xFFFFFF], count: 13)

        let first = device.call("v.oai.thstatus", params: ["threads": big])
        let second = device.call("v.oai.rgbcfg", params: ["z": 1])
        let third = device.call("sys.version", params: nil)
        XCTAssertNotNil(first); XCTAssertNotNil(second); XCTAssertNotNil(third)

        device.flushWritesForTesting()
        XCTAssertGreaterThan(recorder.reports.count, 3, "the big message spans several reports")
        XCTAssertTrue(recorder.reports.allSatisfy { !$0.onMain }, "no SetReport on the main thread")
        XCTAssertEqual(recorder.messages.map { $0["method"] as? String },
                       ["v.oai.thstatus", "v.oai.rgbcfg", "sys.version"])
        XCTAssertEqual(recorder.messages.map { $0["id"] as? Int }, [first, second, third])
    }

    func testCallReturnsBeforeTheWriteFinishes() async {
        let recorder = Recorder()
        recorder.gate = DispatchSemaphore(value: 0)
        let device = WLDevice()
        device.connectForTesting(writer: recorder.write)

        XCTAssertNotNil(device.call("sys.version", params: nil))
        XCTAssertTrue(recorder.reports.isEmpty, "call() did not wait for the radio")
        recorder.gate?.signal()
        device.flushWritesForTesting()
        XCTAssertEqual(recorder.reports.count, 1)
    }

    func testResponsesCompleteOnMain() async throws {
        let recorder = Recorder()
        let device = WLDevice()
        device.connectForTesting(writer: recorder.write)

        let answered = expectation(description: "answered")
        let id = device.call("sys.version", params: nil) { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(error)
            XCTAssertEqual((result as? [String: Any])?["ok"] as? Int, 1)
            answered.fulfill()
        }
        device.flushWritesForTesting()
        device.receiveForTesting(response(id: try XCTUnwrap(id)))
        await fulfillment(of: [answered], timeout: 2)
    }

    func testWriteFailureIsReportedOnMainAndStopsThatMessage() async {
        let recorder = Recorder()
        recorder.failAt = 2
        let device = WLDevice()
        var writeErrors: [String] = []
        device.onWriteError = { method, message in
            XCTAssertTrue(Thread.isMainThread)
            writeErrors.append("\(method): \(message)")
        }
        device.connectForTesting(writer: recorder.write)

        let failed = expectation(description: "failed")
        let big = Array(repeating: ["k": 1, "color": 0xFFFFFF], count: 13)
        device.call("v.oai.thstatus", params: ["threads": big]) { result, error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(result)
            XCTAssertTrue(error?.contains("kIOReturnNotOpen") == true, error ?? "nil")
            failed.fulfill()
        }
        device.flushWritesForTesting()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(recorder.reports.count, 2, "the rest of the message was not sent")
        XCTAssertEqual(writeErrors.count, 1)
        XCTAssertTrue(writeErrors.first?.hasPrefix("v.oai.thstatus: IOHIDDeviceSetReport failed") == true)
    }

    func testDisconnectWhileQueuedDropsTheRestAndCompletesOnce() async {
        let recorder = Recorder()
        recorder.gate = DispatchSemaphore(value: 0)
        let device = WLDevice()
        var writeErrors = 0
        device.onWriteError = { _, _ in writeErrors += 1 }
        device.connectForTesting(writer: recorder.write)

        var completions: [String?] = []
        device.call("first", params: nil) { _, error in completions.append(error) }
        device.call("second", params: nil) { _, error in completions.append(error) }
        // The first write is blocked inside the writer; disconnect now.
        device.disconnect(reason: nil)
        XCTAssertEqual(completions, ["disconnected", "disconnected"])
        XCTAssertFalse(device.isConnected)

        recorder.gate?.signal()
        recorder.gate?.signal()
        device.flushWritesForTesting()
        await drainMain()
        XCTAssertLessThanOrEqual(recorder.reports.count, 1, "the second message was never written")
        XCTAssertEqual(completions.count, 2, "no second completion after disconnect")
        XCTAssertEqual(writeErrors, 0)
        XCTAssertNil(device.call("after", params: nil), "a disconnected device refuses calls")
    }

    func testDisconnectFinishesAMessageAlreadyBeingWritten() async {
        let recorder = Recorder()
        recorder.gate = DispatchSemaphore(value: 0)
        let device = WLDevice()
        device.connectForTesting(writer: recorder.write)

        let big = Array(repeating: ["k": 1, "color": 0xFFFFFF], count: 13)
        device.call("v.oai.thstatus", params: ["threads": big])
        device.call("second", params: nil)
        // Let the first report start (it blocks inside the writer), then
        // disconnect mid-message.
        while recorder.pendingWriters == 0 { await Task.yield() }
        device.disconnect(reason: nil)

        for _ in 0..<64 { recorder.gate?.signal() }
        device.flushWritesForTesting()
        XCTAssertGreaterThan(recorder.reports.count, 1, "the started message spans several reports")
        XCTAssertEqual(recorder.messages.map { $0["method"] as? String }, ["v.oai.thstatus"],
                       "the started message is sent whole; the unstarted one is dropped")
    }

    func testDefaultTimeoutsLeaveRoomForFlash() {
        XCTAssertEqual(WLDevice.defaultTimeout(for: "fs.write"), 30)
        XCTAssertEqual(WLDevice.defaultTimeout(for: "fs.read"), 15)
        XCTAssertEqual(WLDevice.defaultTimeout(for: "v.oai.thstatus"), 8)
    }

    /// The reply timer starts once the last report is written: time spent
    /// waiting on the radio does not count against the firmware.
    func testReplyTimeoutStartsAfterTheLastReport() async throws {
        let recorder = Recorder()
        recorder.gate = DispatchSemaphore(value: 0)
        let device = WLDevice()
        device.perReportAllowance = 30   // keep the outer cap out of the way
        device.connectForTesting(writer: recorder.write)

        var failedAt: Date?
        var failure: String?
        let big = Array(repeating: ["k": 1, "color": 0xFFFFFF], count: 13)
        device.call("v.oai.thstatus", params: ["threads": big], timeout: 0.2) { _, error in
            failure = error
            failedAt = Date()
        }
        // Writes held up well past the reply timeout.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(failure, "still sending, so not timed out")

        let released = Date()
        for _ in 0..<64 { recorder.gate?.signal() }
        device.flushWritesForTesting()
        while failure == nil, Date().timeIntervalSince(released) < 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(failure, "Timed out waiting for v.oai.thstatus.")
        let elapsed = try XCTUnwrap(failedAt).timeIntervalSince(released)
        XCTAssertGreaterThanOrEqual(elapsed, 0.18, "the timer started after the writes, not at queue time")
    }

    /// A reply that arrives while the queue is still busy completes normally.
    func testReplyBeforeTheTimerIsArmedCompletes() async throws {
        let recorder = Recorder()
        let device = WLDevice()
        device.connectForTesting(writer: recorder.write)
        var result: Any?
        var error: String?
        var calls = 0
        let id = try XCTUnwrap(device.call("sys.version", params: nil, timeout: 0.1) { r, e in
            result = r; error = e; calls += 1
        })
        device.receiveForTesting(response(id: id))
        device.flushWritesForTesting()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(error)
        XCTAssertNotNil(result)
    }

    /// A write queue that never gets to the message still fails it.
    func testOuterCapFailsAWedgedQueue() async throws {
        let recorder = Recorder()
        recorder.gate = DispatchSemaphore(value: 0)
        let device = WLDevice()
        device.perReportAllowance = 0.05
        device.connectForTesting(writer: recorder.write)

        var failure: String?
        device.call("sys.version", params: nil, timeout: 0.1) { _, error in failure = error }
        let started = Date()
        while failure == nil, Date().timeIntervalSince(started) < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(failure, "Timed out waiting for sys.version.")
        recorder.gate?.signal()
        device.flushWritesForTesting()
    }

    /// `callAsync` reports an unanswered call as a timeout, distinct from a
    /// device error, so the keymap path can treat it as "unknown".
    func testCallAsyncThrowsTimeout() async {
        let recorder = Recorder()
        let device = WLDevice()
        device.connectForTesting(writer: recorder.write)
        do {
            _ = try await device.callAsync("fs.write", params: ["file": "keymap.json"], timeout: 0.05)
            XCTFail("expected a timeout")
        } catch let failure as WLDevice.Failure {
            XCTAssertTrue(failure.isTimeout, "\(failure)")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testEmulatorAnswersInCallOrder() async {
        let device = WLDevice(emulator: PadEmulator())
        try? device.connect()
        var order: [String] = []
        let done = expectation(description: "all answered")
        done.expectedFulfillmentCount = 3
        for method in ["sys.version", "device.status", "sys.version"] {
            device.call(method, params: nil) { _, _ in order.append(method); done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(order, ["sys.version", "device.status", "sys.version"])
    }
}

/// Preview-paint coalescing: one run in flight, runs spaced out, and the
/// trailing request always runs.
@MainActor
final class CoalescingRunnerTests: XCTestCase {

    func testBurstRunsLeadingAndTrailingOnly() async throws {
        var value = 0
        var painted: [Int] = []
        let runner = CoalescingRunner(interval: 0.1) { painted.append(value) }
        for next in 1...20 {
            value = next
            runner.request()
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(painted, [20], "a synchronous burst coalesces into one run with the latest value")
        XCTAssertFalse(runner.isBusy)
    }

    func testRequestsDuringARunGetOneTrailingRunAfterTheInterval() async throws {
        var runs: [Date] = []
        var values: [Int] = []
        var value = 0
        let runner = CoalescingRunner(interval: 0.15) {
            runs.append(Date())
            values.append(value)
            try? await Task.sleep(nanoseconds: 50_000_000)   // a paint in flight
        }
        value = 1
        runner.request()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(runner.isBusy)
        for next in 2...5 {
            value = next
            runner.request()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(values, [1, 5], "the trailing run paints the latest value")
        XCTAssertEqual(runs.count, 2)
        XCTAssertGreaterThanOrEqual(runs[1].timeIntervalSince(runs[0]), 0.14, "runs start ≥ interval apart")
    }

    func testCancelDropsPending() async throws {
        var count = 0
        let runner = CoalescingRunner(interval: 0.05) {
            count += 1
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        runner.request()
        try await Task.sleep(nanoseconds: 5_000_000)
        runner.request()
        runner.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(runner.isBusy)
    }
}
