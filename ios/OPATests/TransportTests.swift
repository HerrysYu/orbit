import CryptoKit
import XCTest
@testable import OPA

final class LANCandidatesTests: XCTestCase {
    private func addr(_ host: String, _ port: Int = 7420) -> PairingPayload.LanAddr { .init(host: host, port: port) }
    private func hosts(_ list: [PairingPayload.LanAddr]) -> [String] { list.map(\.host) }

    // MARK: Filtering

    func testProxyFakeIPRangeIsDropped() {
        // 198.18.0.0/15 = 198.18.0.0 … 198.19.255.255 (Clash / Surge fake-IP and TUN addresses)
        let out = LANCandidates.ordered([addr("198.18.0.1"), addr("198.19.255.254"), addr("198.18.12.34"), addr("192.168.1.5")])
        XCTAssertEqual(hosts(out), ["192.168.1.5"])
    }

    func testNeighbouringRangesAreKept() {
        let out = LANCandidates.ordered([addr("198.17.255.255"), addr("198.20.0.0"), addr("169.253.1.1"), addr("169.255.1.1")])
        XCTAssertEqual(Set(hosts(out)), ["198.17.255.255", "198.20.0.0", "169.253.1.1", "169.255.1.1"])
    }

    func testLinkLocalIsDropped() {
        let out = LANCandidates.ordered([addr("169.254.0.1"), addr("169.254.200.9"), addr("fe80::1"), addr("[fe80::aaaa:bbbb%en0]"), addr("10.0.0.2")])
        XCTAssertEqual(hosts(out), ["10.0.0.2"])
    }

    func testBadEntriesAreDropped() {
        let out = LANCandidates.ordered([addr(""), addr("  "), addr("192.168.1.2", 0), addr("192.168.1.3", 70_000), addr("192.168.1.4")])
        XCTAssertEqual(hosts(out), ["192.168.1.4"])
    }

    func testDuplicatesAreDropped() {
        let out = LANCandidates.ordered([addr("192.168.1.5"), addr("192.168.1.5"), addr("192.168.1.5", 7421), addr("192.168.1.5")])
        XCTAssertEqual(out.map(\.port), [7420, 7421])
    }

    // MARK: Ordering

    func testPrivateRangesComeFirstThenTheRestAndEachGroupKeepsItsOrder() {
        let out = LANCandidates.ordered([
            addr("8.8.8.8"), addr("192.168.1.5"), addr("100.64.0.2"), addr("10.0.0.2"),
            addr("172.16.0.1"), addr("172.32.0.1"), addr("mac.local"), addr("172.31.255.255"),
        ])
        XCTAssertEqual(hosts(out), ["192.168.1.5", "10.0.0.2", "172.16.0.1", "172.31.255.255",
                                    "8.8.8.8", "100.64.0.2", "172.32.0.1", "mac.local"])
    }

    func testRangeBoundaries() {
        XCTAssertTrue(LANCandidates.isPrivate("10.255.255.255"))
        XCTAssertTrue(LANCandidates.isPrivate("172.16.0.0"))
        XCTAssertTrue(LANCandidates.isPrivate("172.31.0.1"))
        XCTAssertFalse(LANCandidates.isPrivate("172.15.255.255"))
        XCTAssertFalse(LANCandidates.isPrivate("172.32.0.0"))
        XCTAssertTrue(LANCandidates.isPrivate("192.168.0.1"))
        XCTAssertFalse(LANCandidates.isPrivate("192.169.0.1"))
        XCTAssertFalse(LANCandidates.isPrivate("11.0.0.1"))
        XCTAssertFalse(LANCandidates.isPrivate("not-an-ip"))
        XCTAssertFalse(LANCandidates.isPrivate("1.2.3"))
        XCTAssertFalse(LANCandidates.isPrivate("1.2.3.256"))
    }

    func testIPv6AndNamesAreKeptInTheOtherGroup() {
        let out = LANCandidates.ordered([addr("fd00::1"), addr("2001:db8::5"), addr("macbook.local"), addr("192.168.0.9")])
        XCTAssertEqual(hosts(out), ["192.168.0.9", "fd00::1", "2001:db8::5", "macbook.local"])
    }

    // MARK: Final dial order

    func testBonjourResultsGoFirstThenThePayloadAddresses() {
        let bonjour = [URL(string: "ws://192.168.1.99:7420/v1/ws")!]
        let urls = LANCandidates.candidateURLs(bonjour: bonjour, payload: [addr("8.8.8.8"), addr("198.18.0.2"), addr("10.0.0.5"), addr("169.254.3.3")])
        XCTAssertEqual(urls.map(\.absoluteString), ["ws://192.168.1.99:7420/v1/ws", "ws://10.0.0.5:7420/v1/ws", "ws://8.8.8.8:7420/v1/ws"])
    }

    func testBonjourDuplicatesOfPayloadAddressesAppearOnce() {
        let bonjour = [URL(string: "ws://192.168.1.5:7420/v1/ws")!]
        let urls = LANCandidates.candidateURLs(bonjour: bonjour, payload: [addr("192.168.1.5"), addr("192.168.1.6")])
        XCTAssertEqual(urls.map(\.absoluteString), ["ws://192.168.1.5:7420/v1/ws", "ws://192.168.1.6:7420/v1/ws"])
    }

    func testBonjourProxyAddressesAreDroppedButScopedIPv6IsAllowed() {
        let bonjour = [URL(string: "ws://198.18.0.7:7420/v1/ws")!, URL(string: "ws://[fe80::1%25en0]:7420/v1/ws")!]
        let urls = LANCandidates.candidateURLs(bonjour: bonjour, payload: [])
        XCTAssertEqual(urls.map(\.absoluteString), ["ws://[fe80::1%25en0]:7420/v1/ws"])
    }

    func testIPv6HostsGetBracketsInUrls() {
        XCTAssertEqual(LANCandidates.url(host: "fd00::1", port: 7420)?.absoluteString, "ws://[fd00::1]:7420/v1/ws")
        XCTAssertEqual(LANCandidates.url(host: "192.168.1.5", port: 7420)?.absoluteString, "ws://192.168.1.5:7420/v1/ws")
    }

    // MARK: Pairing payload and stored hosts

    private func payloadLink(lan: [PairingPayload.LanAddr]) throws -> String {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        let payload = PairingPayload(v: 1, hostId: OPACrypto.id(ofPublicKey: pub), hostPub: pub.base64EncodedString(), hostName: "Mac",
                                     lan: lan, relay: "wss://relay.example.workers.dev", pairToken: "tok", exp: nil)
        return "opa://pair?d=" + (try JSONEncoder().encode(payload)).base64URLEncodedString()
    }

    func testParsingAPairingLinkDropsProxyAndLinkLocalAddresses() throws {
        let link = try payloadLink(lan: [addr("198.18.0.1"), addr("203.0.113.9"), addr("169.254.8.8"), addr("192.168.1.5")])
        let p = try PairingPayload.parse(link)
        XCTAssertEqual(hosts(p.lan), ["192.168.1.5", "203.0.113.9"])
    }

    func testAPairedHostNeverStoresBadAddresses() throws {
        let p = try PairingPayload.parse(payloadLink(lan: [addr("198.19.0.1"), addr("10.1.1.1")]))
        XCTAssertEqual(hosts(PairedHost(payload: p).lan), ["10.1.1.1"])
    }

    func testHostsPairedByAnOlderBuildAreCleanedWhenLoaded() {
        let suite = UserDefaults(suiteName: "opa.tests." + UUID().uuidString)!
        let payload = PairingPayload(v: 1, hostId: "h", hostPub: "p", hostName: "Mac", lan: [], relay: nil, pairToken: nil, exp: nil)
        var dirty = PairedHost(payload: payload)
        dirty.lan = [addr("198.18.0.1"), addr("169.254.1.1"), addr("192.168.5.5")]   // as an old build would have saved it
        dirty.save(to: suite)
        XCTAssertEqual(hosts(PairedHost.load(from: suite)?.lan ?? []), ["192.168.5.5"])
        PairedHost.clear(from: suite)
        XCTAssertNil(PairedHost.load(from: suite))
    }
}

final class HeartbeatPolicyTests: XCTestCase {
    func testDefaultsAre15SecondsPingEightSecondTimeoutTwoStrikes() {
        let p = HeartbeatPolicy()
        XCTAssertEqual(p.interval, .seconds(15))
        XCTAssertEqual(p.timeout, .seconds(8))
        XCTAssertEqual(p.maxConsecutiveFailures, 2)
    }

    func testTwoConsecutiveFailuresMeanReconnect() {
        var p = HeartbeatPolicy()
        XCTAssertFalse(p.record(success: false), "one miss is tolerated")
        XCTAssertTrue(p.record(success: false), "the second in a row tears the connection down")
    }

    func testASuccessResetsTheCount() {
        var p = HeartbeatPolicy()
        XCTAssertFalse(p.record(success: false))
        XCTAssertFalse(p.record(success: true))
        XCTAssertFalse(p.record(success: false))
        XCTAssertTrue(p.record(success: false))
    }

    func testResetClearsTheCount() {
        var p = HeartbeatPolicy()
        _ = p.record(success: false)
        p.reset()
        XCTAssertFalse(p.record(success: false))
        XCTAssertEqual(p.consecutiveFailures, 1)
    }

    func testNetworkChangeDetection() {
        let wifi = NetworkPathSignature(isSatisfied: true, interfaces: ["wifi:en0"], gateways: ["192.168.1.1"])
        let wifi2 = NetworkPathSignature(isSatisfied: true, interfaces: ["wifi:en0"], gateways: ["10.0.0.1"])
        let cellular = NetworkPathSignature(isSatisfied: true, interfaces: ["cellular:pdp_ip0"], gateways: [])
        let none = NetworkPathSignature(isSatisfied: false, interfaces: [], gateways: [])
        XCTAssertFalse(NetworkPathSignature.shouldReconnect(from: nil, to: wifi), "the first report is only the starting point")
        XCTAssertFalse(NetworkPathSignature.shouldReconnect(from: wifi, to: wifi))
        XCTAssertTrue(NetworkPathSignature.shouldReconnect(from: wifi, to: cellular), "Wi-Fi → cellular")
        XCTAssertTrue(NetworkPathSignature.shouldReconnect(from: wifi, to: wifi2), "another Wi-Fi network")
        XCTAssertTrue(NetworkPathSignature.shouldReconnect(from: wifi, to: none), "network lost")
        XCTAssertTrue(NetworkPathSignature.shouldReconnect(from: none, to: wifi), "network back")
    }

    func testSignatureIgnoresInterfaceOrder() {
        XCTAssertEqual(NetworkPathSignature(isSatisfied: true, interfaces: ["b", "a"], gateways: ["y", "x"]),
                       NetworkPathSignature(isSatisfied: true, interfaces: ["a", "b"], gateways: ["x", "y"]))
    }
}

@MainActor
final class LivenessMonitorTests: XCTestCase {
    private func fast(failures: Int = 2) -> HeartbeatPolicy {
        var p = HeartbeatPolicy()
        p.interval = .milliseconds(10)
        p.timeout = .milliseconds(5)
        p.maxConsecutiveFailures = failures
        return p
    }

    func testTwoMissedPingsInARowDeclareTheConnectionDead() async {
        var probes = 0
        let dead = await ConnectionManager.monitorLiveness(policy: fast(), isCurrent: { true }) {
            probes += 1
            return false
        }
        XCTAssertTrue(dead)
        XCTAssertEqual(probes, 2, "exactly two misses, then it stops")
    }

    func testAnAnsweredPingInBetweenKeepsTheConnection() async {
        let answers: [Bool?] = [false, true, false, true, false, true]
        var i = 0
        let task = Task { @MainActor in
            await ConnectionManager.monitorLiveness(policy: fast(), isCurrent: { true }) {
                defer { i += 1 }
                return i < answers.count ? answers[i] : true
            }
        }
        try? await Task.sleep(for: .milliseconds(250))
        task.cancel()
        let dead = await task.value
        XCTAssertFalse(dead, "never two misses in a row")
        XCTAssertGreaterThan(i, answers.count)
    }

    func testNothingToJudgeForgetsEarlierMisses() async {
        let answers: [Bool?] = [false, nil, false, nil, false]
        var i = 0
        let task = Task { @MainActor in
            await ConnectionManager.monitorLiveness(policy: fast(), isCurrent: { true }) {
                defer { i += 1 }
                return i < answers.count ? answers[i] : nil
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let dead = await task.value
        XCTAssertFalse(dead, "a reconnect in between means the earlier miss is moot")
    }

    func testASupersededMonitorStopsQuietly() async {
        var current = true
        var probes = 0
        let task = Task { @MainActor in
            await ConnectionManager.monitorLiveness(policy: fast(failures: 1), isCurrent: { current }) {
                probes += 1
                return false
            }
        }
        current = false   // the run loop was replaced before the first ping
        let dead = await task.value
        XCTAssertFalse(dead, "an outdated monitor must not tear down the new connection")
        XCTAssertEqual(probes, 0)
    }

    func testCancellationEndsTheMonitor() async {
        let task = Task { @MainActor in
            await ConnectionManager.monitorLiveness(policy: fast(), isCurrent: { true }) { true }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let dead = await task.value
        XCTAssertFalse(dead)
    }
}

@MainActor
final class ReconnectTriggerTests: XCTestCase {
    private func wifi(_ gateway: String) -> NetworkPathSignature {
        NetworkPathSignature(isSatisfied: true, interfaces: ["wifi:en0"], gateways: [gateway])
    }

    /// A manager pointed at an address nothing listens on (no relay): it keeps retrying quietly, which is all we need.
    private func makeManager(pairing: Bool = false) throws -> ConnectionManager {
        let identity = DeviceIdentity(privateKey: Curve25519.Signing.PrivateKey())
        let manager = ConnectionManager(identity: identity, deviceName: "test")
        let hostKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let payload = PairingPayload(v: 1, hostId: OPACrypto.id(ofPublicKey: hostKey), hostPub: hostKey.base64EncodedString(), hostName: "Mac",
                                     lan: [.init(host: "127.0.0.1", port: 1)], relay: nil, pairToken: pairing ? "tok" : nil, exp: nil)
        if pairing { manager.startPairing(payload) } else { manager.start(host: PairedHost(payload: payload)) }
        // The real path monitor reports once right after it starts; let that settle so it is the baseline.
        return manager
    }

    private func settle(_ manager: ConnectionManager) async {
        try? await Task.sleep(for: .milliseconds(400))
        manager.pathChanged(wifi("baseline"))   // whatever the real monitor said, this is now the known path
        try? await Task.sleep(for: .milliseconds(400))
    }

    func testANetworkChangeReconnectsImmediately() async throws {
        let m = try makeManager()
        defer { m.stop() }
        await settle(m)
        let before = m.restartCount
        m.pathChanged(wifi("changed"))
        let restarted = await waitUntil(timeout: 2) { m.restartCount == before + 1 }
        XCTAssertTrue(restarted, "Wi-Fi → another network must not wait for a timeout")
    }

    func testTheSamePathAgainDoesNothing() async throws {
        let m = try makeManager()
        defer { m.stop() }
        await settle(m)
        let before = m.restartCount
        m.pathChanged(wifi("baseline"))
        m.pathChanged(wifi("baseline"))
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(m.restartCount, before)
    }

    func testABurstOfPathReportsCausesOneReconnect() async throws {
        let m = try makeManager()
        defer { m.stop() }
        await settle(m)
        let before = m.restartCount
        m.pathChanged(wifi("a"))
        m.pathChanged(NetworkPathSignature(isSatisfied: true, interfaces: ["cellular:pdp_ip0"], gateways: []))
        m.pathChanged(wifi("b"))
        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(m.restartCount, before + 1, "reports within the debounce window collapse into one reconnect")
    }

    func testPairingIsNeverInterruptedByANetworkChange() async throws {
        let m = try makeManager(pairing: true)
        defer { m.stop() }
        await settle(m)
        let before = m.restartCount
        m.pathChanged(wifi("changed"))
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(m.restartCount, before, "the pairing token is single use: a silent reconnect would burn it")
    }

    func testAStoppedManagerIgnoresPathChanges() async throws {
        let m = try makeManager()
        await settle(m)
        m.stop()
        let before = m.restartCount
        m.pathChanged(wifi("x"))
        m.pathChanged(wifi("y"))
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(m.restartCount, before)
        XCTAssertEqual(m.state, .idle)
        m.kick()   // no target: nothing happens
        XCTAssertEqual(m.state, .idle)
    }
}
