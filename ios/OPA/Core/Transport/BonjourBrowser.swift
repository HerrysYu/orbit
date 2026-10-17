import Foundation
import Network

/// Browses `_opa._tcp` and indexes services by the `hostId` TXT record.
@MainActor
final class BonjourBrowser {
    private var browser: NWBrowser?
    private(set) var endpoints: [String: [NWEndpoint]] = [:]

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_opa._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var map: [String: [NWEndpoint]] = [:]
            for r in results {
                if case .bonjour(let txt) = r.metadata, let id = txt["hostId"] {
                    map[id.lowercased(), default: []].append(r.endpoint)
                }
            }
            Task { @MainActor in self?.endpoints = map }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { @MainActor in
                    self?.browser?.cancel()
                    self?.browser = nil
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// After a network change the old results (and the browser's sockets) may be stale.
    func restart() {
        stop()
        endpoints = [:]
        start()
    }

    func endpoints(for hostId: String) -> [NWEndpoint] { endpoints[hostId.lowercased()] ?? [] }

    /// Resolves a Bonjour service endpoint into a concrete `ws://ip:port/v1/ws` URL.
    nonisolated static func resolve(_ endpoint: NWEndpoint, timeout: Duration = .seconds(1)) async -> URL? {
        let conn = NWConnection(to: endpoint, using: .tcp)
        let box = ResumeOnce<URL?>()
        return await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
            box.set(c)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var url: URL?
                    if case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint {
                        url = wsURL(host: host, port: port.rawValue)
                    }
                    conn.cancel()
                    box.resume(url)
                case .failed, .cancelled:
                    box.resume(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: timeout)
                conn.cancel()
                box.resume(nil)
            }
        }
    }

    nonisolated static func wsURL(host: NWEndpoint.Host, port: UInt16) -> URL? {
        switch host {
        case .ipv4(let a):
            let s = "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
            return URL(string: "ws://\(s):\(port)/v1/ws")
        case .ipv6(let a):
            let s = "\(a)".replacingOccurrences(of: "%", with: "%25")
            return URL(string: "ws://[\(s)]:\(port)/v1/ws")
        case .name(let n, _):
            return URL(string: "ws://\(n):\(port)/v1/ws")
        @unknown default:
            return nil
        }
    }
}

/// Resumes a continuation at most once from any thread.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T, Never>?
    func set(_ c: CheckedContinuation<T, Never>) { lock.withLock { self.c = c } }
    func resume(_ value: T) {
        let c = lock.withLock { () -> CheckedContinuation<T, Never>? in defer { self.c = nil }; return self.c }
        c?.resume(returning: value)
    }
}
