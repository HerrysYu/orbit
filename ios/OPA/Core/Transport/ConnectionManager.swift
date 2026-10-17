import CryptoKit
import Foundation
import Network
import os

private let log = Logger(subsystem: "com.haoyuanyu.orbit", category: "connection")

/// Liveness policy for an established connection: ping every `interval`; a ping that is not answered within
/// `timeout` is a failure; `maxConsecutiveFailures` failures in a row mean the socket is dead and the connection
/// must be torn down and re-established.
struct HeartbeatPolicy: Equatable, Sendable {
    var interval: Duration = .seconds(15)
    var timeout: Duration = .seconds(8)
    var maxConsecutiveFailures = 2
    private(set) var consecutiveFailures = 0

    /// Records one ping result. Returns true when the connection should be torn down and re-established.
    mutating func record(success: Bool) -> Bool {
        if success {
            consecutiveFailures = 0
            return false
        }
        consecutiveFailures += 1
        return consecutiveFailures >= maxConsecutiveFailures
    }

    mutating func reset() { consecutiveFailures = 0 }
}

/// One answered `ping`: the Mac's clock (`ts` in the response) and when we sent / got it, both in phone Unix ms.
struct PongSample: Sendable, Equatable {
    var hostTs: Int64?
    var sentAt: Int64
    var receivedAt: Int64
}

/// A coarse fingerprint of the network path (status, interfaces, gateways). When it changes, sockets opened on the
/// old path are probably dead even though nothing has told us so.
struct NetworkPathSignature: Equatable, Sendable {
    var isSatisfied: Bool
    var interfaces: [String]
    var gateways: [String]

    init(isSatisfied: Bool, interfaces: [String], gateways: [String]) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces.sorted()
        self.gateways = gateways.sorted()
    }

    init(_ path: NWPath) {
        self.init(isSatisfied: path.status == .satisfied,
                  interfaces: path.availableInterfaces.map { "\($0.type):\($0.name)" },
                  gateways: path.gateways.map { "\($0)" })
    }

    /// The first report is only the starting point; any later difference means "reconnect now".
    static func shouldReconnect(from previous: NetworkPathSignature?, to current: NetworkPathSignature) -> Bool {
        guard let previous else { return false }
        return previous != current
    }
}

/// Owns the transport: path selection (LAN → relay), handshake, encryption, req/res correlation,
/// relay control frames, liveness (heartbeat ping, network-path changes) and reconnect with exponential
/// backoff + jitter.
@MainActor
final class ConnectionManager {
    // MARK: Inputs / outputs

    var onState: (ConnectionState) -> Void = { _ in }
    var onMessage: (InboundMessage) -> Void = { _ in }
    /// Called after every successful handshake (including re-handshake after host_online).
    var onSessionReady: () async -> Void = {}
    /// Called once when a pairing completes successfully.
    var onPaired: (PairedHost) -> Void = { _ in }
    /// Called whenever a heartbeat ping is answered (the Mac is demonstrably there; the sample carries its clock).
    var onPong: (PongSample) -> Void = { _ in }

    /// Heartbeat timing (15 s interval, 8 s timeout, 2 consecutive failures). Adjustable for tests.
    var heartbeat = HeartbeatPolicy()
    /// How many times the connection was thrown away and re-dialed at once (network change, lost heartbeat, foreground
    /// probe). Diagnostics and tests.
    private(set) var restartCount = 0

    private(set) var state: ConnectionState = .idle {
        didSet {
            guard state != oldValue else { return }
            log.info("state: \(self.state.label, privacy: .public)")   // `label` never contains the pairing code
            onState(state)
        }
    }
    private(set) var hostName: String?
    private(set) var lastPath: TransportPath?

    let identity: DeviceIdentity
    var deviceName: String

    private var target: Target?
    private let bonjour = BonjourBrowser()

    private var ws: WebSocket?
    private var channel: SecureChannel?
    private var runTask: Task<Void, Never>?
    /// Bumped whenever the run loop is replaced (stop, restart, reconfigure) so a superseded loop never touches
    /// the shared socket / state again.
    private var generation = 0
    private var attempt = 0
    private var wakeContinuation: CheckedContinuation<Void, Never>?

    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: NetworkPathSignature?
    private var pathDebounce: Task<Void, Never>?

    /// What the relay last said about the Mac (`host_online` / `host_offline`). Nil: nothing yet, or not on the relay.
    private var relayHostOnline: Bool?

    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var handshakeWaiter: CheckedContinuation<WelcomeFrame, any Error>?
    private var pairWaiter: CheckedContinuation<Bool, any Error>?
    private var hostOnlineWaiter: CheckedContinuation<Void, any Error>?

    struct Target: Sendable {
        var hostId: String
        var hostPubRaw: Data
        var hostName: String
        var lan: [PairingPayload.LanAddr]
        var relay: String?
        var pairToken: String?
        var pairPayload: PairingPayload?
    }

    init(identity: DeviceIdentity, deviceName: String) {
        self.identity = identity
        self.deviceName = deviceName
    }

    // MARK: Public control

    func start(host: PairedHost) {
        configure(Target(hostId: host.hostId, hostPubRaw: host.hostPubRaw, hostName: host.hostName,
                         lan: host.lan, relay: host.relay, pairToken: nil, pairPayload: nil))
    }

    func startPairing(_ p: PairingPayload) {
        configure(Target(hostId: p.hostId, hostPubRaw: p.hostPubRaw, hostName: p.hostName,
                         lan: p.lan, relay: p.relay, pairToken: p.pairToken, pairPayload: p))
    }

    private func configure(_ t: Target) {
        stop()
        target = t
        hostName = t.hostName
        bonjour.start()
        startPathMonitor()
        attempt = 0
        launchLoop()
    }

    /// Full stop: no target, no run loop, no socket. (A later `kick()` does nothing until `start` is called again.)
    func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        target = nil
        stopPathMonitor()
        teardown(error: OPAError.cancelled)
        wake()
        state = .idle
    }

    /// Foreground: reconnect now (skips any backoff wait). A connection that looks healthy is probed with a ping
    /// instead, because a socket that sat in the background is often dead without anyone having noticed; when the Mac
    /// was reported offline the whole connection is redone, since it may be reachable on the LAN by now.
    func kick() {
        guard target != nil else { return }
        attempt = 0
        if runTask == nil { launchLoop(); return }
        switch state {
        case .connected: probeNow()
        case .hostOffline: restartLoop(reason: "foreground while the Mac was offline")
        default: wake()
        }
    }

    func suspend() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        stopPathMonitor()
        teardown(error: OPAError.notConnected)
        bonjour.stop()
        state = .idle
    }

    private func launchLoop() {
        let gen = generation
        runTask = Task { [weak self] in await self?.runLoop(generation: gen) }
    }

    /// Throws the current connection away and dials again right away (no backoff).
    /// Used when the network path changed or the heartbeat says the socket is dead.
    private func restartLoop(reason: String) {
        guard target != nil else { return }
        log.notice("reconnecting now: \(reason, privacy: .public)")
        restartCount += 1
        generation += 1
        runTask?.cancel()
        teardown(error: OPAError.notConnected)
        wake()
        attempt = 0
        state = .connecting
        launchLoop()
    }

    // MARK: Liveness

    /// An app-level `ping`; nil when it was not answered in time.
    private func ping(timeout: Duration) async -> PongSample? {
        let sent = Clock.nowMs
        do {
            let res = try await request("ping", [:], timeout: timeout)
            return PongSample(hostTs: res["ts"]?.int64, sentAt: sent, receivedAt: Clock.nowMs)
        } catch {
            return nil
        }
    }

    /// One immediate ping (foreground). A single failure is enough to reconnect: the app just came back to life.
    private func probeNow() {
        let gen = generation
        Task { [weak self] in
            guard let self else { return }
            if let sample = await self.ping(timeout: self.heartbeat.timeout) {
                self.onPong(sample)
            } else if gen == self.generation, self.state.isConnected {
                self.restartLoop(reason: "no answer to the ping after returning to the foreground")
            }
        }
    }

    /// Pings every `interval` while connected (an app-level `ping` request, which also proves the Mac answers),
    /// or a WebSocket ping while we only wait for the Mac to come back (relay says host offline).
    /// Two consecutive failures tear the connection down and reconnect.
    private func heartbeatLoop(generation gen: Int) async {
        let dead = await Self.monitorLiveness(policy: heartbeat, isCurrent: { [weak self] in self?.generation == gen }) { [weak self] in
            guard let self else { return nil }
            if self.state.isConnected {
                let sample = await self.ping(timeout: self.heartbeat.timeout)
                if let sample, self.generation == gen { self.onPong(sample) }
                log.debug("heartbeat ping: \(sample == nil ? "no answer" : "ok", privacy: .public)")
                return sample != nil
            }
            if case .hostOffline = self.state, let socket = self.ws {
                let ok = await socket.ping(timeout: self.heartbeat.timeout)
                log.debug("heartbeat websocket ping (Mac offline): \(ok ? "ok" : "no answer", privacy: .public)")
                return ok
            }
            return nil   // handshaking / reconnecting: nothing to judge
        }
        if dead, gen == generation { restartLoop(reason: "heartbeat lost (\(heartbeat.maxConsecutiveFailures) missed pings in a row)") }
    }

    /// Runs `probe` every `policy.interval` until the surrounding task is cancelled, `isCurrent` turns false, or the
    /// probe has failed `policy.maxConsecutiveFailures` times in a row. Returns true in the last case: the
    /// connection is dead and must be re-established. `probe` answers true (alive), false (no answer) or nil (nothing
    /// to judge right now, which also forgets earlier misses).
    static func monitorLiveness(policy: HeartbeatPolicy, isCurrent: @MainActor () -> Bool,
                                probe: @MainActor () async -> Bool?) async -> Bool {
        var policy = policy
        policy.reset()
        while !Task.isCancelled {
            try? await Task.sleep(for: policy.interval)
            guard !Task.isCancelled, isCurrent() else { return false }
            let alive = await probe()
            guard !Task.isCancelled, isCurrent() else { return false }
            guard let alive else { policy.reset(); continue }
            if policy.record(success: alive) { return true }
        }
        return false
    }

    // MARK: Network path

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = NetworkPathSignature(path)
            Task { @MainActor in self?.pathChanged(signature) }
        }
        monitor.start(queue: DispatchQueue(label: "opa.connection.path"))
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
        pathDebounce?.cancel()
        pathDebounce = nil
    }

    /// The network changed (Wi-Fi ↔ cellular, new Wi-Fi, lost / regained). Sockets from the old path are dead or about
    /// to be: reconnect immediately instead of waiting for a timeout. Pairing is left alone (its token is single use).
    func pathChanged(_ signature: NetworkPathSignature) {
        let previous = lastPathSignature
        lastPathSignature = signature
        guard NetworkPathSignature.shouldReconnect(from: previous, to: signature),
              let target, target.pairToken == nil else { return }
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            // Path reports usually come in bursts (interfaces, then gateways, then DNS).
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.target != nil else { return }
            self.bonjour.restart()
            self.restartLoop(reason: "network path changed")
        }
    }

    // MARK: Requests

    func request(_ m: String, _ d: JSONValue = [:], timeout: Duration = .seconds(20)) async throws -> JSONValue {
        guard state.isConnected, channel != nil else { throw OPAError.notConnected }
        let id = ShortID.make()
        let frame: JSONValue = ["t": "req", "id": .string(id), "m": .string(m), "d": d]
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.pending.removeValue(forKey: id)?.resume(throwing: OPAError.timeout)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do {
                try sendEncrypted(frame)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    // MARK: Run loop

    private func runLoop(generation gen: Int) async {
        while !Task.isCancelled, gen == generation, let target {
            do {
                try await connectOnce(target, generation: gen)
                // Connection ended normally (socket closed) — fall through to retry.
            } catch is CancellationError {
                return
            } catch OPAError.rejected(let reason) {
                guard gen == generation else { return }
                state = .failed("Mac 拒绝了连接：\(reason)")
                if target.pairToken != nil { runTask = nil; return }
            } catch let e as PairingFailure {
                guard gen == generation else { return }
                state = .failed(e.localizedDescription)
                runTask = nil
                return
            } catch {
                if Task.isCancelled { return }
            }
            // A superseded loop (restart / stop) must not touch the shared socket or state any more.
            guard !Task.isCancelled, gen == generation else { return }
            teardown(error: OPAError.notConnected)
            // Exponential backoff with full jitter: 0.5s → 30s.
            let base = min(30.0, 0.5 * pow(2.0, Double(attempt)))
            let delay = base * Double.random(in: 0.5...1.0)
            attempt += 1
            if case .failed = state {} else {
                state = .waitingRetry(seconds: max(1, Int(delay.rounded())), reason: "")
            }
            await sleepOrWake(delay)
        }
    }

    private func sleepOrWake(_ seconds: Double) async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.wake() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wakeContinuation = c
        }
        timer.cancel()
    }

    private func wake() {
        wakeContinuation?.resume()
        wakeContinuation = nil
    }

    struct PairingFailure: Error, LocalizedError {
        var errorDescription: String? { "配对被拒绝或已失效，请在 Mac 上重新执行 opa pair" }
    }

    private func connectOnce(_ t: Target, generation gen: Int) async throws {
        state = .connecting
        let (socket, path) = try await openBestPath(t)
        if Task.isCancelled || gen != generation {
            socket.close()
            throw CancellationError()
        }
        ws = socket
        lastPath = path
        relayHostOnline = nil
        let receiver = Task { [weak self] in await self?.receiveLoop(socket) }
        defer { receiver.cancel() }
        // Liveness: the connection is pinged every 15 s from the moment it exists (also while we wait for the Mac
        // to come back); two misses in a row reconnect.
        let beat = Task { [weak self] in await self?.heartbeatLoop(generation: gen) }
        defer { beat.cancel() }

        if path == .relay { try await waitForRelayHost() }
        try await handshake(t, path: path)
        attempt = 0
        await onSessionReady()

        // Stay here until the socket dies; re-handshake on host_online.
        while !Task.isCancelled {
            try await waitForHostOnline()
            state = .handshaking(path)
            try await handshake(t, path: path)
            await onSessionReady()
        }
    }

    /// Relay only. Right after connecting the relay says whether the Mac is there. A hello sent to an absent Mac is
    /// dropped (the handshake would only time out and the UI would flap), so while the Mac is offline we wait here
    /// with the state `.hostOffline` until the relay reports it back.
    private func waitForRelayHost() async throws {
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while relayHostOnline == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        while relayHostOnline == false {
            try await waitForHostOnline()
        }
    }

    private func handshake(_ t: Target, path: TransportPath) async throws {
        state = .handshaking(path)
        channel = nil
        let eph = Curve25519.KeyAgreement.PrivateKey()
        let ephDRaw = eph.publicKey.rawRepresentation
        let ephDB64 = ephDRaw.base64EncodedString()
        let ts = Clock.nowMs
        let sig = try identity.sign(OPACrypto.helloMessage(hostId: t.hostId, ephPubB64: ephDB64, ts: ts))
        let hello = HelloFrame(deviceId: identity.deviceId, devicePub: identity.publicKeyB64, deviceName: deviceName,
                               ephPub: ephDB64, ts: ts, pairToken: t.pairToken, sig: sig.base64EncodedString())
        let helloText = String(decoding: try JSONEncoder().encode(hello), as: UTF8.self)

        let welcomeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.handshakeWaiter?.resume(throwing: OPAError.timeout)
            self?.handshakeWaiter = nil
        }
        defer { welcomeTimer.cancel() }
        // A failed send surfaces as a receive error, which tears down and fails the waiter.
        let welcome: WelcomeFrame = try await withCheckedThrowingContinuation { c in
            handshakeWaiter = c
            ws?.send(helloText)
        }

        guard OPACrypto.verify(signatureB64: welcome.sig,
                               message: OPACrypto.welcomeMessage(deviceId: identity.deviceId, ephPubDB64: ephDB64, ephPubHB64: welcome.ephPub),
                               publicKeyRaw: t.hostPubRaw),
              let ephHRaw = Data(base64Encoded: welcome.ephPub), ephHRaw.count == 32
        else { throw OPAError.protocolViolation("Mac 身份校验失败") }

        let keys = try OPACrypto.deriveSessionKeys(myEph: eph, peerEphRaw: ephHRaw, ephDRaw: ephDRaw, ephHRaw: ephHRaw)
        channel = SecureChannel(keys: keys, isDevice: true)
        if let name = welcome.hostName { hostName = name }

        if !welcome.paired {
            guard t.pairToken != nil else { throw PairingFailure() }
            state = .awaitingPairConfirm(sas: keys.sas, path: path)
            let pairTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.pairWaiter?.resume(throwing: OPAError.timeout)
                self?.pairWaiter = nil
            }
            defer { pairTimer.cancel() }
            let ok = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, any Error>) in
                pairWaiter = c
            }
            guard ok else { throw PairingFailure() }
            if var p = t.pairPayload {
                p.hostName = hostName ?? p.hostName
                let host = PairedHost(payload: p)
                host.save()
                target?.pairToken = nil
                target?.pairPayload = nil
                onPaired(host)
            }
        } else if let p = t.pairPayload {
            // Already whitelisted (re-pair of a known device).
            var p2 = p
            p2.hostName = hostName ?? p.hostName
            let host = PairedHost(payload: p2)
            host.save()
            target?.pairToken = nil
            target?.pairPayload = nil
            onPaired(host)
        }
        state = .connected(path)
    }

    private func waitForHostOnline() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            hostOnlineWaiter = c
        }
    }

    // MARK: Path selection

    private func openBestPath(_ t: Target) async throws -> (WebSocket, TransportPath) {
        // Bonjour-resolved endpoints first, then the pairing payload's private-range addresses, then the rest.
        // Proxy fake-IPs (198.18/15) and link-local addresses are never dialed.
        let endpoints = bonjour.endpoints(for: t.hostId)
        var resolved: [URL] = []
        if !endpoints.isEmpty {
            resolved = await withTaskGroup(of: URL?.self) { g in
                for e in endpoints { g.addTask { await BonjourBrowser.resolve(e) } }
                var out: [URL] = []
                for await u in g { if let u { out.append(u) } }
                return out
            }
        }
        let lanURLs = LANCandidates.candidateURLs(bonjour: resolved, payload: t.lan)

        if !lanURLs.isEmpty, let socket = await race(lanURLs, timeout: .milliseconds(1500)) {
            return (socket, .lan)
        }
        try Task.checkCancellation()

        guard let relayURL = relayURL(t) else { throw OPAError.notConnected }
        let socket = WebSocket(url: relayURL)
        try await socket.open(timeout: .seconds(10))
        return (socket, .relay)
    }

    /// Opens the candidates "happy eyeballs" style: the first starts at once, each later one a little afterwards,
    /// so the preferred (earlier) address wins whenever it is reachable. The first socket to open wins.
    private nonisolated func race(_ urls: [URL], timeout: Duration, stagger: Duration = .milliseconds(150)) async -> WebSocket? {
        await withTaskGroup(of: WebSocket?.self) { g in
            for (i, u) in urls.enumerated() {
                g.addTask {
                    if i > 0 {
                        try? await Task.sleep(for: stagger * i)
                        if Task.isCancelled { return nil }
                    }
                    let s = WebSocket(url: u)
                    do { try await s.open(timeout: timeout); return s } catch { return nil }
                }
            }
            var winner: WebSocket?
            for await s in g {
                if let s {
                    if winner == nil { winner = s; g.cancelAll() } else { s.close() }
                }
            }
            return winner
        }
    }

    private func relayURL(_ t: Target) -> URL? {
        guard var base = t.relay, !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        let ts = Clock.nowMs
        guard let sig = try? identity.sign(OPACrypto.relayDeviceMessage(hostId: t.hostId, deviceId: identity.deviceId, ts: ts)) else {
            return nil
        }
        var comps = URLComponents(string: "\(base)/v1/device/\(t.hostId)")
        var q = [
            URLQueryItem(name: "deviceId", value: identity.deviceId),
            URLQueryItem(name: "pub", value: identity.publicKeyRaw.base64URLEncodedString()),
            URLQueryItem(name: "ts", value: String(ts)),
            URLQueryItem(name: "sig", value: sig.base64URLEncodedString()),
        ]
        if t.pairToken != nil { q.append(URLQueryItem(name: "pair", value: "1")) }
        comps?.queryItems = q
        return comps?.url
    }

    // MARK: Receive

    private func receiveLoop(_ socket: WebSocket) async {
        while !Task.isCancelled {
            let text: String
            do {
                text = try await socket.receive()
            } catch {
                if ws === socket { teardown(error: OPAError.notConnected) }
                return
            }
            guard ws === socket else { return }
            handleFrame(text)
        }
    }

    private func handleFrame(_ text: String) {
        guard let v = try? JSONValue(jsonString: text) else { return }

        if let control = v["relay"]?.string {
            switch control {
            case "host_offline":
                relayHostOnline = false
                state = .hostOffline
                // Nothing in flight can be answered any more: after the Mac comes back the channel is re-established
                // with new keys. (A resent `chat.send` is de-duplicated by its clientId.)
                failPendingRequests(OPAError.notConnected)
                // A hello that was already sent has been dropped by the relay: do not wait out the handshake timeout.
                if let c = handshakeWaiter {
                    handshakeWaiter = nil
                    c.resume(throwing: OPAError.notConnected)
                }
            case "host_online":
                relayHostOnline = true
                if let c = hostOnlineWaiter {
                    hostOnlineWaiter = nil
                    c.resume()
                }
            default: break
            }
            return
        }

        switch v["t"]?.string {
        case "welcome":
            if let w = try? v.decode(WelcomeFrame.self) {
                handshakeWaiter?.resume(returning: w)
                handshakeWaiter = nil
            }
        case "reject":
            let reason = v["reason"]?.string ?? "未知原因"
            handshakeWaiter?.resume(throwing: OPAError.rejected(reason))
            handshakeWaiter = nil
            teardown(error: OPAError.rejected(reason))
        case "x":
            guard var ch = channel, let n = v["n"]?.double, n >= 0, let c = v["c"]?.string else { return }
            do {
                let plain = try ch.openFrame(n: UInt64(n), c: c)
                channel = ch
                let msg = InboundMessage(try JSONValue(data: plain))
                dispatch(msg)
            } catch {
                // Replay or forgery: must disconnect.
                teardown(error: OPAError.protocolViolation(error.localizedDescription))
            }
        default:
            break
        }
    }

    private func dispatch(_ msg: InboundMessage) {
        switch msg {
        case .res(let id, let ok, let d, let err):
            guard let c = pending.removeValue(forKey: id) else { return }
            if ok { c.resume(returning: d ?? .null) } else { c.resume(throwing: OPAError.remote(err ?? "请求失败")) }
        case .pairResult(let ok):
            pairWaiter?.resume(returning: ok)
            pairWaiter = nil
            onMessage(msg)
        default:
            onMessage(msg)
        }
    }

    private func sendEncrypted(_ v: JSONValue) throws {
        guard var ch = channel, let ws else { throw OPAError.notConnected }
        let text = try ch.sealFrame(try v.data())
        channel = ch
        // Send errors surface through the receive loop, which tears the connection down.
        ws.send(text)
    }

    // MARK: Teardown

    private func failPendingRequests(_ error: any Error) {
        let all = pending
        pending.removeAll()
        for (_, c) in all { c.resume(throwing: error) }
    }

    private func teardown(error: any Error) {
        ws?.close()
        ws = nil
        channel = nil
        relayHostOnline = nil
        failPendingRequests(error)
        handshakeWaiter?.resume(throwing: error); handshakeWaiter = nil
        pairWaiter?.resume(throwing: error); pairWaiter = nil
        hostOnlineWaiter?.resume(throwing: error); hostOnlineWaiter = nil
    }
}


extension ConnectionManager: HostBackend {}
