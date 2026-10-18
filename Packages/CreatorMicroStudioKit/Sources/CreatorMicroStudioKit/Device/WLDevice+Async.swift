import Foundation

extension WLDevice {
    /// async/await over the completion-based `call`.
    ///
    /// All mutable transport state and callbacks are serialized on the main
    /// actor. Requiring that actor here avoids crossing an unisolated GCD
    /// closure with this non-Sendable IOKit owner.
    ///
    /// A call the firmware never answered throws `Failure.timeout`, so a
    /// caller can tell "no reply" (the device may still have acted) from an
    /// error the device returned.
    @MainActor
    public func callAsync(_ method: String, params: Any? = nil, timeout: TimeInterval? = nil) async throws -> Any? {
        let timeoutText = WLDevice.Failure.timeout(method).errorDescription
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let finish: (Result<Any?, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            let sent = self.call(method, params: params, timeout: timeout) { result, error in
                if let error {
                    finish(.failure(error == timeoutText
                                    ? WLDevice.Failure.timeout(method)
                                    : WLDevice.Failure.rpc(method, error)))
                } else {
                    finish(.success(result))
                }
            }
            if sent == nil {
                // `call` refuses before sending when there is no device or
                // the write fails; the completion already carried the
                // reason, so this only covers the silent case.
                finish(.failure(WLDevice.Failure.notConnected))
            }
        }
    }
}

extension WLDevice.Failure {
    /// The device never answered (it may still have acted on the call).
    public var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}
