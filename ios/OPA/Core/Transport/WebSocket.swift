import Foundation

/// Thin wrapper over URLSessionWebSocketTask with an awaitable open + timeout.
/// Sends use the completion-handler API so frames are enqueued strictly in call order
/// (required: the receiver rejects any out-of-order nonce counter).
final class WebSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var closed = false

    init(url: URL) {
        self.url = url
        super.init()
    }

    func open(timeout: Duration) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        lock.withLock {
            self.session = session
            self.task = task
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { self?.finishOpen(OPAError.timeout) }
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let alreadyClosed = lock.withLock { () -> Bool in
                    if closed { return true }
                    openContinuation = c
                    return false
                }
                if alreadyClosed { c.resume(throwing: CancellationError()) } else { task.resume() }
            }
        } onCancel: {
            self.finishOpen(CancellationError())
        }
    }

    private func finishOpen(_ error: (any Error)?) {
        let c = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { openContinuation = nil }
            return openContinuation
        }
        guard let c else { return }
        if let error {
            close()
            c.resume(throwing: error)
        } else {
            c.resume()
        }
    }

    func send(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void = { _ in }) {
        guard let task = lock.withLock({ task }) else {
            completion(OPAError.notConnected)
            return
        }
        task.send(.string(text), completionHandler: completion)
    }

    func receive() async throws -> String {
        guard let task = lock.withLock({ task }) else { throw OPAError.notConnected }
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: throw OPAError.protocolViolation("未知帧类型")
        }
    }

    /// Transport-level liveness probe (a WebSocket ping frame). True when the pong arrives within `timeout`.
    func ping(timeout: Duration) async -> Bool {
        guard let task = lock.withLock({ task }) else { return false }
        let box = ResumeOnce<Bool>()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            box.set(c)
            task.sendPing { error in box.resume(error == nil) }
            Task {
                try? await Task.sleep(for: timeout)
                box.resume(false)
            }
        }
    }

    func close() {
        let (t, s) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            closed = true
            defer { task = nil; session = nil }
            return (task, session)
        }
        t?.cancel(with: .normalClosure, reason: nil)
        s?.invalidateAndCancel()
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        finishOpen(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finishOpen(error ?? OPAError.notConnected)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finishOpen(OPAError.notConnected)
    }
}
