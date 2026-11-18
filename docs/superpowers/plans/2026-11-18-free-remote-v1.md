# Free Remote for Samsung TV — v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A free iPhone app that discovers Samsung Tizen TVs on the local network and controls them like the physical remote (layout B), ready for App Store submission.

**Architecture:** A local Swift package `SamsungTVKit` (no UI; builds for iOS 27 *and* macOS 27 so its tests run fast with `swift test` and a `tvprobe` CLI can talk to real TVs from the Mac) holds discovery, device info, pairing/session, commands, wake and power logic behind small protocols. The SwiftUI app target holds view models, platform stores (Keychain, iCloud KVS, file), and screens.

**Tech Stack:** Swift 6.4 (Swift 6 language mode, strict concurrency), SwiftUI + Observation, Network.framework, URLSession WebSocket, Security.framework, Swift Testing, XCTest UI tests. Xcode 27.2. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-18-samsung-tv-remote-design.md`

## Global Constraints

- iOS 27.0 deployment target; iPhone only (`TARGETED_DEVICE_FAMILY = 1`). Package platforms: `.iOS("27.0")`, `.macOS("27.0")`.
- Swift 6 language mode, complete strict concurrency; no `@unchecked Sendable` without a comment proving safety.
- Apple frameworks only — no SPM dependencies, no CocoaPods, no analytics/crash SDKs.
- Display name `Free Remote for Samsung TV`; pairing name sent to TVs is the constant `Free Remote`.
- Control channel only `wss://<host>:8002/api/v2/channels/samsung.remote.control`; port 8001 used only for `GET http://<host>:8001/api/v2/`.
- Never trust-all TLS; trust-on-first-use SPKI SHA-256 pinning.
- Only private (RFC1918) or link-local IPv4 hosts are ever contacted.
- Nothing specific to the owner's network/TVs in code, config, or fixtures; nothing personal or signing-related committed (`Config/Local.xcconfig` is git-ignored; owner's copy lives in the private notes repo `../samsung-free-remote-ios-app-private`).
- Commit **and push** after every task (`git push origin main`). Before each public commit run `../samsung-free-remote-ios-app-private/privacy-check.sh` (it greps staged changes for the owner's identifiers, which are deliberately kept out of this repo); it must print nothing and exit 0.
- Logging via `os.Logger`; hosts and MACs logged with `privacy: .private`; tokens never logged.
- Kit tests: `swift test --package-path SamsungTVKit`. App tests: `xcodebuild test -project FreeRemote.xcodeproj -scheme FreeRemote -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=27.1'`.

## Review Focus

1. **TV's IP changes (DHCP) between launches** → found again by `id`, host updated, pairing token and label kept. Test: `KnownTVRegistryTests.ipChangeKeepsIdentity` (Task 5) and `AppModelTests.reconnectsAfterIPChange` (Task 14).
2. **Hold-to-repeat interrupted** (app backgrounded, finger slides off, connection drops mid-hold) → repeating stops immediately; no runaway volume. Test: `RepeatControllerTests.cancelStopsRepeatingAndSendsRelease` (Task 14).
3. **Power pressed twice quickly / stale state** → one power action in flight; second press ignored until it finishes. Test: `PowerControllerTests.concurrentPressIsIgnored` (Task 11).
4. **Phone not on Wi-Fi (cellular only, Wi-Fi off)** → "Connect to Wi-Fi" state, no scan, no broadcast address computed from a non-Wi-Fi interface. Test: `NetworkInterfacesTests.noWiFiReturnsNil` (Task 10) and `AppModelTests.noWiFiShowsWiFiState` (Task 14).
5. **Non-Samsung or hostile device answers on 8001/SSDP** (garbage, huge body, HTML, non-Tizen JSON, public IP in LOCATION) → silently ignored, never crashes. Tests: `TVDeviceInfoTests.rejectsNonTizen`, `HTTPTVInfoFetcherTests.rejectsOversizedBody` (Tasks 1–2), `SSDPTests.ignoresPublicLocation` (Task 3).

---

## File Structure

```
SamsungTVKit/
  Package.swift
  Sources/SamsungTVKit/
    Model/TVID.swift, TVDeviceInfo.swift, HTMLEntities.swift, MACAddress.swift, KnownTV.swift
    Network/LocalAddress.swift, HTTPTVInfoFetcher.swift, NetworkInterfaces.swift
    Discovery/SSDP.swift, SSDPSearcher.swift, BonjourSamsungBrowser.swift, DiscoveryCoordinator.swift
    Remote/RemoteKey.swift, RemoteProtocol.swift, CertificatePin.swift, PinningDelegate.swift,
           WebSocketTransport.swift, Backoff.swift, RemoteSession.swift, CredentialStore.swift
    Power/WakeOnLAN.swift, PowerPlanner.swift, PowerController.swift
  Sources/tvprobe/main.swift
  Tests/SamsungTVKitTests/…  (+ Fixtures/*.json, anonymised)
  Tests/SamsungTVKitIntegrationTests/FakeTV.swift, FakeTVTests.swift (+ Fixtures/fake-tv-identity.p12, test-only)
FreeRemote.xcodeproj           (file-system synchronized groups → adding files never edits pbxproj)
App/FreeRemote/                FreeRemoteApp.swift, AppModel.swift, RepeatController.swift,
                               Stores/{KeychainCredentialStore,ICloudLabelStore,FileKnownTVStore}.swift,
                               Views/{RemoteView,TVPicker,DPad,Rocker,RemoteButton,StatusView,
                                      NumberPadSheet,TextEntrySheet,RenameSheet,AddTVSheet}.swift,
                               Demo/DemoEnvironment.swift, Resources/, FreeRemote.entitlements, Info.plist
App/FreeRemoteTests/           AppModelTests.swift, RepeatControllerTests.swift, StoreTests.swift
App/FreeRemoteUITests/         FlowUITests.swift, ScreenshotTests.swift
Config/Base.xcconfig, Config/Local.example.xcconfig
AppStore/listing.md, AppStore/review-notes.md
docs/privacy/index.md          (GitHub Pages privacy policy)
docs/testing/manual-checklist.md
.github/workflows/ci.yml, .github/ISSUE_TEMPLATE/*.md
README.md, LICENSE (MIT), CONTRIBUTING.md
```

---

### Task 1: Package scaffold + device info model

**Files:**
- Create: `SamsungTVKit/Package.swift`, `Sources/SamsungTVKit/Model/{TVID,TVDeviceInfo,HTMLEntities,MACAddress}.swift`, `Tests/SamsungTVKitTests/{TVDeviceInfoTests,HTMLEntitiesTests,MACAddressTests}.swift`, `Tests/SamsungTVKitTests/Fixtures/{info-on.json,info-asleep.json,info-non-tizen.json}`, `LICENSE` (MIT, "Copyright (c) 2026 Free Remote contributors"), `README.md` (stub: one paragraph + privacy stance), `.github/workflows/ci.yml` (macOS runner with Xcode 27; runs kit tests; app tests added in Task 13)
- Modify: `.gitignore` (+ `Config/Local.xcconfig`)

**Interfaces:**
- Produces:
  - `public struct TVID: Hashable, Codable, Sendable { public let rawValue: String }`
  - `public enum TVPowerState: Equatable, Sendable { case on, standby, unknown(String) }` — `"on"`→`.on`; `""` and `"standby"`→`.standby`; anything else→`.unknown`.
  - `public struct MACAddress: Hashable, Codable, Sendable { public init?(_ string: String); public let bytes: [UInt8] /* 6 */ ; public var description: String /* "AA:BB:…" */ }`
  - `public struct TVDeviceInfo: Equatable, Sendable { id: TVID; host: String; name: String; modelName: String; modelCode: String; wifiMAC: MACAddress?; networkType: String; powerState: TVPowerState; tokenAuthSupported: Bool }`
  - `public static func TVDeviceInfo.decode(_ data: Data, host: String) throws(TVInfoError) -> TVDeviceInfo`
  - `public enum TVInfoError: Error, Equatable { case malformed, notSamsungTizen, tooLarge, unreachable, notLocalAddress }`
  - `public enum HTMLEntities { public static func decode(_ s: String) -> String }`

Fixtures are copies of the real `/api/v2/` responses with **anonymised** values (`"id":"uuid:00000000-0000-4000-8000-000000000001"`, name `65&quot; Test TV`, MAC `02:00:00:00:00:01`, ip `10.0.0.5`).

- [ ] **Step 1: Write failing tests**
```swift
@Test func decodesOnTV() throws {
  let info = try TVDeviceInfo.decode(fixture("info-on"), host: "10.0.0.5")
  #expect(info.id == TVID(rawValue: "uuid:00000000-0000-4000-8000-000000000001"))
  #expect(info.name == "65\" Test TV")           // entity-decoded
  #expect(info.powerState == .on)
  #expect(info.wifiMAC?.description == "02:00:00:00:00:01")
  #expect(info.tokenAuthSupported)
}
@Test func emptyPowerStateIsStandby() throws { #expect(try TVDeviceInfo.decode(fixture("info-asleep"), host: "10.0.0.5").powerState == .standby) }
@Test func rejectsNonTizen() { #expect(throws: TVInfoError.notSamsungTizen) { try TVDeviceInfo.decode(fixture("info-non-tizen"), host: "10.0.0.5") } }
@Test func rejectsGarbage() { #expect(throws: TVInfoError.malformed) { try TVDeviceInfo.decode(Data("<html>".utf8), host: "10.0.0.5") } }
@Test(arguments: [("85&quot; A","85\" A"),("A &amp; B","A & B"),("&#39;x&#39;","'x'"),("&lt;&gt;","<>"),("plain","plain"),("&bogus;","&bogus;")])
func entities(input: String, expected: String) { #expect(HTMLEntities.decode(input) == expected) }
@Test func macParsing() { #expect(MACAddress("02:00:00:0a:0b:0c")?.bytes.count == 6); #expect(MACAddress("nope") == nil); #expect(MACAddress("") == nil) }
```
- [ ] **Step 2:** Run `swift test --package-path SamsungTVKit` → FAIL (types missing).
- [ ] **Step 3:** Implement. Decode with `JSONDecoder` into private DTOs mirroring `{"device":{…}}`; require `type == "Samsung SmartTV"` and `OS == "Tizen"`; `TokenAuthSupport` arrives as the *string* `"true"`.
- [ ] **Step 4:** Run tests → PASS.
- [ ] **Step 5:** Commit `feat(kit): package scaffold and TV device info model` and push.

### Task 2: Local address guard + HTTP info fetcher

**Files:** Create `Network/LocalAddress.swift`, `Network/HTTPTVInfoFetcher.swift`; Tests `LocalAddressTests.swift`, `HTTPTVInfoFetcherTests.swift` (use a `URLProtocol` stub).

**Interfaces:**
- Consumes: `TVDeviceInfo.decode`, `TVInfoError`.
- Produces:
  - `public enum LocalAddress { public static func isAllowed(_ host: String) -> Bool }` — true only for IPv4 literals in 10/8, 172.16/12, 192.168/16, 169.254/16. Hostnames → false.
  - `public protocol TVInfoFetching: Sendable { func fetchInfo(host: String) async throws(TVInfoError) -> TVDeviceInfo }`
  - `public struct HTTPTVInfoFetcher: TVInfoFetching { public init(session: URLSession = .shared, timeout: Duration = .seconds(2), maxBytes: Int = 64 * 1024) }`

- [ ] **Step 1: Failing tests:** `isAllowed` table (`"10.0.0.1"`✓, `"172.31.255.1"`✓, `"172.32.0.1"`✗, `"192.168.0.9"`✓, `"8.8.8.8"`✗, `"169.254.3.3"`✓, `"tv.local"`✗, `"192.168.1.300"`✗, `""`✗); `fetchRejectsPublicHost` → `.notLocalAddress` with zero requests made; `rejectsOversizedBody` (70 KB body → `.tooLarge`); `timeoutMapsToUnreachable`; `success` decodes fixture and requests exactly `http://10.0.0.5:8001/api/v2/`.
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement using `URLSession.bytes(for:)`, aborting once `maxBytes` exceeded; map URL errors → `.unreachable`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(kit): local address guard and TV info fetcher`; push.

### Task 3: SSDP search

**Files:** Create `Discovery/SSDP.swift`, `Discovery/SSDPSearcher.swift`; Test `SSDPTests.swift`.

**Interfaces:**
- Produces:
  - `public protocol CandidateSource: Sendable { func candidates() -> AsyncStream<String> /* hosts; finishes when source stops */ }`
  - `public enum SSDP { static let targets = ["urn:samsung.com:device:RemoteControlReceiver:1", "urn:dial-multiscreen-org:service:dial:1"]; static func searchRequest(target: String) -> Data; static func host(fromResponse: Data) -> String? }`
  - `public struct SSDPSearcher: CandidateSource { public init(duration: Duration = .seconds(4), repeats: Int = 3) }` — `NWConnectionGroup` on `239.255.255.250:1900`; yields the responder's host only if `LocalAddress.isAllowed` and the `SERVER` header contains `Samsung`; if the group fails (no entitlement) it logs and finishes the stream (never throws to callers).
- [ ] **Step 1: Failing tests:** `searchRequest` exact bytes (`M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: "ssdp:discover"\r\nMX: 2\r\nST: <target>\r\n\r\n`); `host(fromResponse:)` extracts `10.0.0.5` from a captured Samsung response (anonymised); returns nil for Sonos/Hue `SERVER`; `ignoresPublicLocation` (LOCATION `http://8.8.8.8:7678/…` → nil); case-insensitive headers; 100 KB junk → nil.
- [ ] **Step 2–4:** Run → FAIL; implement (parse headers case-insensitively, cap 8 KB); run → PASS.
- [ ] **Step 5:** Commit `feat(kit): SSDP search`; push.

### Task 4: Bonjour (AirPlay) browser

**Files:** Create `Discovery/BonjourSamsungBrowser.swift`; Test `BonjourTests.swift`.

**Interfaces:**
- Produces:
  - `public enum BonjourTXT { public static func isSamsung(_ txt: [String: String]) -> Bool }` — `manufacturer` equals `Samsung` (case-insensitive).
  - `public struct BonjourSamsungBrowser: CandidateSource { public init(duration: Duration = .seconds(4)) }` — `NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil))`; for Samsung results, resolve the endpoint to an IPv4 host via a short-lived `NWConnection` (`currentPath?.remoteEndpoint`), filter with `LocalAddress.isAllowed`.
- [ ] **Step 1: Failing tests:** `isSamsung` true for `["manufacturer":"Samsung","model":"R95H"]`, `["manufacturer":"samsung"]`; false for Sonos/Apple/empty.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(kit): Bonjour AirPlay browser for Samsung TVs`; push.

### Task 5: Known TVs + discovery coordinator

**Files:** Create `Model/KnownTV.swift`, `Discovery/DiscoveryCoordinator.swift`; Tests `KnownTVRegistryTests.swift`, `DiscoveryCoordinatorTests.swift`.

**Interfaces:**
- Consumes: `CandidateSource`, `TVInfoFetching`, `TVDeviceInfo`.
- Produces:
  - `public struct KnownTV: Codable, Equatable, Sendable { id: TVID; lastHost: String; wifiMAC: MACAddress?; modelName: String; reportedName: String; lastSeen: Date }`
  - `public struct KnownTVRegistry: Codable, Equatable, Sendable { public private(set) var tvs: [TVID: KnownTV]; public mutating func record(_ info: TVDeviceInfo, at: Date); public mutating func forget(_ id: TVID) }`
  - `public actor DiscoveryCoordinator { public init(sources: [any CandidateSource], fetcher: any TVInfoFetching, knownHosts: [String]); public func scan() -> AsyncStream<TVDeviceInfo> }` — merges sources + known hosts, fetches each distinct host once per scan (max 8 concurrent), yields each `TVID` once.
- [ ] **Step 1: Failing tests:** `ipChangeKeepsIdentity` (record id X @10.0.0.5, then id X @10.0.0.9 → one entry, `lastHost == "10.0.0.9"`, name/MAC refreshed); `forgetRemoves`; coordinator with two fake sources yielding the same host and a known host → fetch called once per host; two hosts returning same id → yielded once; fetch failures skipped; stream finishes when all sources finish.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(kit): known TV registry and discovery coordinator`; push.

### Task 6: Remote protocol messages

**Files:** Create `Remote/RemoteKey.swift`, `Remote/RemoteProtocol.swift`; Test `RemoteProtocolTests.swift`.

**Interfaces:**
- Produces:
  - `public enum RemoteKey: String, Sendable, CaseIterable` — cases with raw values: `power="KEY_POWER", up="KEY_UP", down="KEY_DOWN", left="KEY_LEFT", right="KEY_RIGHT", enter="KEY_ENTER", back="KEY_RETURN", home="KEY_HOME", volumeUp="KEY_VOLUP", volumeDown="KEY_VOLDOWN", mute="KEY_MUTE", channelUp="KEY_CHUP", channelDown="KEY_CHDOWN", source="KEY_SOURCE", hdmi1…hdmi4="KEY_HDMI1"…"KEY_HDMI4", play="KEY_PLAY", pause="KEY_PAUSE", digit0…digit9="KEY_0"…"KEY_9"`.
  - `public enum KeyAction: String, Sendable { case click = "Click", press = "Press", release = "Release" }`
  - `public enum RemoteProtocol { static let pairingName = "Free Remote"; static func channelURL(host: String, token: String?) -> URL; static func key(_: RemoteKey, _: KeyAction) -> Data; static func text(_: String) -> Data; static func decodeEvent(_: Data) -> ChannelEvent }`
  - `public enum ChannelEvent: Equatable, Sendable { case connected(token: String?), unauthorized, timedOut, keyboardShown, keyboardHidden, other(String) }` — from `event` values `ms.channel.connect`, `ms.channel.unauthorized`, `ms.channel.timeOut`/`ms.channel.timeout`, `ms.remote.imeStart`, `ms.remote.imeEnd`.
- [ ] **Step 1: Failing tests:** `channelURL(host:"10.0.0.5", token:nil)` == `wss://10.0.0.5:8002/api/v2/channels/samsung.remote.control?name=RnJlZSBSZW1vdGU=`; with token appends `&token=abc` (percent-encoded); `key(.volumeUp,.click)` JSON equals `{"method":"ms.remote.control","params":{"Cmd":"Click","DataOfCmd":"KEY_VOLUP","Option":"false","TypeOfRemote":"SendRemoteKey"}}` (compare parsed dictionaries); `text("hé")` → `Cmd` = base64 of UTF-8, `DataOfCmd":"base64"`, `TypeOfRemote":"SendInputString"`; decode `{"event":"ms.channel.connect","data":{"token":"123"}}` → `.connected(token:"123")`; unauthorized; both timeout spellings; garbage → `.other("")`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(kit): Samsung remote protocol messages`; push.

### Task 7: Certificate pinning + transport

**Files:** Create `Remote/CertificatePin.swift`, `Remote/PinningDelegate.swift`, `Remote/WebSocketTransport.swift`, `Remote/CredentialStore.swift`; Test `CertificatePinTests.swift`.

**Interfaces:**
- Produces:
  - `public struct CertificatePin: Codable, Hashable, Sendable { public let sha256: Data; public static func of(_ trust: SecTrust) -> CertificatePin? /* SHA-256 of leaf SecKeyCopyExternalRepresentation */ }`
  - `public enum PinPolicy: Sendable { case recordFirstUse, require(CertificatePin) }`
  - `public struct TVCredentials: Codable, Equatable, Sendable { public var token: String?; public var pin: CertificatePin }`
  - `public protocol CredentialStore: Sendable { func load(_ id: TVID) -> TVCredentials?; func save(_ c: TVCredentials, for id: TVID) throws; func delete(_ id: TVID) }`
  - `public protocol WebSocketTransport: Sendable { func connect(_ url: URL, policy: PinPolicy) async throws(TransportError) -> CertificatePin; func send(_ data: Data) async throws(TransportError); func receive() async throws(TransportError) -> Data; func close() async }`
  - `public enum TransportError: Error, Equatable { case pinMismatch, unreachable, closed }`
  - `public final class URLSessionWebSocketTransport: WebSocketTransport` — `PinningDelegate` accepts the server trust **only** when policy is `.recordFirstUse` (recording the pin) or the presented pin equals the required one; otherwise cancels the challenge → `.pinMismatch`. Messages are text frames; max incoming message 256 KB; ping every 15 s.
- [ ] **Step 1: Failing tests:** `CertificatePin.of` on a trust built from the test fixture cert returns a stable 32-byte hash equal to a hard-coded value computed once with `openssl` (record command in test comment); two different certs → different pins.
- [ ] **Step 2–4:** FAIL → implement → PASS (end-to-end pin behaviour is covered in Task 9).
- [ ] **Step 5:** Commit `feat(kit): TLS pinning and WebSocket transport`; push.

### Task 8: Remote session

**Files:** Create `Remote/Backoff.swift`, `Remote/RemoteSession.swift`; Tests `BackoffTests.swift`, `RemoteSessionTests.swift` (fake transport + `TestClock`-style manual clock written in the test target).

**Interfaces:**
- Consumes: `RemoteProtocol`, `WebSocketTransport`, `CredentialStore`, `TVID`.
- Produces:
  - `public struct Backoff: Sendable { public init(base: Duration = .milliseconds(500), max: Duration = .seconds(30)); public func delay(attempt: Int) -> Duration /* base·2^attempt, capped */ }`
  - `public enum SessionState: Equatable, Sendable { case idle, connecting, awaitingApproval, connected, failed(SessionError) }`
  - `public enum SessionError: Error, Equatable, Sendable { case denied, approvalTimedOut, identityChanged, unreachable }`
  - `public actor RemoteSession { public init(id: TVID, host: String, credentials: any CredentialStore, transport: @Sendable () -> any WebSocketTransport, clock: any Clock<Duration> = ContinuousClock(), approvalTimeout: Duration = .seconds(30)); public var states: AsyncStream<SessionState> { get }; public var keyboardEvents: AsyncStream<Bool> { get }; public func connect() async; public func send(_ key: RemoteKey, _ action: KeyAction = .click) async throws(SessionError); public func sendText(_ s: String) async throws(SessionError); public func disconnect() async }`
  - Behaviour: no stored credentials → `.connecting` → `.awaitingApproval` until `.connected(token)` → save `TVCredentials(token, pin)` → `.connected`. Stored credentials → connect with `.require(pin)` + token. `.unauthorized` → `.failed(.denied)` and delete credentials. `pinMismatch` → `.failed(.identityChanged)` (credentials kept until user re-pairs). Unexpected close while connected → reconnect with `Backoff`; after 5 failed attempts → `.failed(.unreachable)`. `disconnect()` stops reconnecting. `send` while not connected → throws `.unreachable` (never silently drops).
- [ ] **Step 1: Failing tests:** `firstPairingSavesTokenAndPin`; `storedCredentialsUseRequirePolicyAndToken`; `deniedDeletesCredentials`; `approvalTimeout` (advance manual clock 30 s → `.failed(.approvalTimedOut)`); `pinMismatchReportsIdentityChanged`; `dropReconnectsWithBackoff` (delays 0.5, 1, 2 s); `disconnectStopsReconnect`; `sendWhileDisconnectedThrows`; `keyboardEventsForwarded`; Backoff table (0→0.5 s, 3→4 s, 10→30 s).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(kit): remote session with pairing and reconnect`; push.

### Task 9: Fake TV + integration tests

**Files:** Create `Tests/SamsungTVKitIntegrationTests/FakeTV.swift`, `FakeTVTests.swift`, `Fixtures/fake-tv-identity.p12` (self-signed, generated with `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes -subj "/CN=FakeTV"` then `openssl pkcs12 -export -passout pass:test`; README note in the fixture folder: test-only, not a secret). Add the target in `Package.swift`.

**Interfaces:**
- Produces: `final class FakeTV` — `NWListener` on 127.0.0.1 random ports: HTTP `/api/v2/` returning a fixture; TLS WebSocket server using the p12 identity that replies `ms.channel.connect` with token `"fake-token"` (or `ms.channel.unauthorized` when `denyPairing = true`) and records received messages. `LocalAddress.isAllowed` gets an internal test-only hook allowing `127.0.0.1` (`@_spi(Testing)`), never enabled in production.
- [ ] **Step 1: Failing tests:** `pairsThenReconnectsWithToken` (second connection URL contains `token=fake-token`); `rejectsDifferentCertificate` (restart FakeTV with a second identity → `.failed(.identityChanged)`); `keyArrivesAtTV` (send `.volumeUp` → FakeTV received the exact JSON); `deniedPairing`.
- [ ] **Step 2–4:** FAIL → implement FakeTV → PASS.
- [ ] **Step 5:** Commit `test(kit): fake TV integration tests`; push.

### Task 10: Wake-on-LAN + interfaces

**Files:** Create `Network/NetworkInterfaces.swift`, `Power/WakeOnLAN.swift`; Tests `WakeOnLANTests.swift`, `NetworkInterfacesTests.swift`.

**Interfaces:**
- Produces:
  - `public struct IPv4Interface: Equatable, Sendable { public let name: String; public let address: UInt32; public let netmask: UInt32; public var broadcast: String { get } /* (address & mask) | ~mask, dotted */ }`
  - `public enum NetworkInterfaces { public static func wifiIPv4(from list: [IPv4Interface]) -> IPv4Interface? /* first "en0" with a private address */; public static func current() -> [IPv4Interface] /* getifaddrs */ }`
  - `public enum WakeOnLAN { public static func magicPacket(for: MACAddress) -> Data; public static func send(to mac: MACAddress, via: IPv4Interface, repeats: Int = 3) async }` — UDP port 9 to `via.broadcast` and `255.255.255.255`, via `NWConnection`; errors logged, not thrown.
- [ ] **Step 1: Failing tests:** packet is 102 bytes, first 6 are `0xFF`, then the 6 MAC bytes ×16; broadcast for 192.168.1.100/255.255.255.0 → `192.168.1.255`, 10.1.2.3/255.255.0.0 → `10.1.255.255`, 172.16.5.4/255.255.255.252 → `172.16.5.7`; `noWiFiReturnsNil` (only `pdp_ip0` + `lo0`) → nil; `en0` with public address → nil.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(kit): wake-on-LAN and interface broadcast address`; push.

### Task 11: Power planner + controller

**Files:** Create `Power/PowerPlanner.swift`, `Power/PowerController.swift`; Tests `PowerControllerTests.swift`.

**Interfaces:**
- Consumes: `TVInfoFetching`, `RemoteSession`, `WakeOnLAN`, `NetworkInterfaces`.
- Produces:
  - `public enum PowerAction: Equatable, Sendable { case turnOff, wakeFromStandby, wakeOnLAN }`
  - `public enum PowerPlanner { public static func action(for result: Result<TVPowerState, TVInfoError>) -> PowerAction }` — `.success(.on)`→`.turnOff`; `.success(.standby | .unknown)`→`.wakeFromStandby`; `.failure`→`.wakeOnLAN`.
  - `public enum PowerOutcome: Equatable, Sendable { case turnedOff, turnedOn, failedToWake, noMACKnown, notOnWiFi }`
  - `public actor PowerController { public init(fetcher: any TVInfoFetching, wake: @Sendable (MACAddress, IPv4Interface) async -> Void, interface: @Sendable () -> IPv4Interface?, clock: any Clock<Duration> = ContinuousClock(), wakeTimeout: Duration = .seconds(20)); public func togglePower(tv: KnownTV, session: RemoteSession) async -> PowerOutcome? /* nil = ignored because one is in flight */ }`
  - Behaviour: fetch info (1 s timeout); `.turnOff`/`.wakeFromStandby` send `.power` via session (connecting first if needed); `.wakeOnLAN` sends magic packet then polls info every 1 s until `.on` or timeout.
- [ ] **Step 1: Failing tests:** planner table; `concurrentPressIsIgnored` (second call while first pending returns nil); `wolPollsUntilOn` (fetcher fails twice then `.on` → `.turnedOn`, wake called once); `wolTimeout` → `.failedToWake`; no MAC → `.noMACKnown`; no interface → `.notOnWiFi`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(kit): state-aware power control`; push.

### Task 12: `tvprobe` CLI + real-TV verification

**Files:** Create `Sources/tvprobe/main.swift` (executable target). Results go to the **private** repo `../samsung-free-remote-ios-app-private/protocol-findings.md`; generic conclusions (no identifiers) go to `docs/protocol-notes.md` in the public repo.

**Interfaces:** Consumes the whole kit. Subcommands: `tvprobe discover`, `tvprobe info <host>`, `tvprobe key <host> <KEY> [click|press|release]`, `tvprobe hold <host> <KEY> <seconds>`, `tvprobe text <host> <string>`, `tvprobe listen <host>`, `tvprobe wake <mac>`. Credentials stored in a JSON file under `~/Library/Application Support/tvprobe/` (dev tool only).

- [ ] **Step 1:** `swift build --package-path SamsungTVKit --product tvprobe` → builds.
- [ ] **Step 2:** `tvprobe discover` lists all 3 owner TVs (owner keeps them on). Expected: three distinct ids.
- [ ] **Step 3:** Pair each TV (owner presses **Allow**); re-run a key → no prompt, pin reused.
- [ ] **Step 4:** Verify and record: (a) `hold … KEY_VOLUP 2` with Press/Release vs repeated Click — which repeats correctly; (b) which of `KEY_PLAY`/`KEY_PAUSE`/`KEY_PLAY_BACK` toggles playback in an app; (c) `listen` while focusing a TV search box → exact IME event names, then `text`; (d) put a TV to standby with its remote → `info` PowerState value per model, and whether `key KEY_POWER` wakes it; (e) `KEY_HDMI1..4` per model; (f) after ~30 min standby, is the TV still reachable; `wake <mac>` from the Mac then.
- [ ] **Step 5:** Apply findings to the kit: update `RemoteKey`, `ChannelEvent` mapping, and the repeat strategy constant `RepeatStrategy` (`.pressRelease` or `.clickEvery(Duration)`, add to `RemoteKey.swift`); adjust/added tests; run kit tests → PASS.
- [ ] **Step 6:** Commit (public: `feat(kit): tvprobe and protocol adjustments from real-TV testing`; private: findings); push both.

### Task 13: Xcode app project + platform stores

**Files:** Create `FreeRemote.xcodeproj` (targets `FreeRemote`, `FreeRemoteTests`, `FreeRemoteUITests`; synchronized folders `App/…`; local package dependency `SamsungTVKit`), `Config/Base.xcconfig` (`#include? "Local.xcconfig"`; defaults `PRODUCT_BUNDLE_IDENTIFIER = org.example.FreeRemote`, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`, `TARGETED_DEVICE_FAMILY = 1`, `SWIFT_VERSION = 6`, `SWIFT_STRICT_CONCURRENCY = complete`), `Config/Local.example.xcconfig`, `App/FreeRemote/Info.plist` (`CFBundleDisplayName` = `Free Remote for Samsung TV`, `NSLocalNetworkUsageDescription` = "Free Remote looks for Samsung TVs on your Wi-Fi network so you can control them.", `NSBonjourServices` = `[_airplay._tcp]`, `NSAppTransportSecurity.NSAllowsLocalNetworking` = YES, `ITSAppUsesNonExemptEncryption` = NO, portrait only), `FreeRemote.entitlements` (`com.apple.developer.networking.multicast`, `com.apple.developer.ubiquity-kvstore-identifier`), `Stores/{KeychainCredentialStore,ICloudLabelStore,FileKnownTVStore}.swift`, `FreeRemoteTests/StoreTests.swift`. Copy owner's `Config/Local.xcconfig` from the private repo locally (git-ignored). Add app build+test job to CI (with `CODE_SIGNING_ALLOWED=NO`).

**Interfaces:**
- Consumes: `CredentialStore`, `KnownTVRegistry`, `TVID`.
- Produces:
  - `struct KeychainCredentialStore: CredentialStore { init(service: String = "FreeRemote.credentials") }` — `kSecClassGenericPassword`, account = `TVID.rawValue`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, JSON-encoded `TVCredentials`.
  - `protocol LabelStore: Sendable { func label(for: TVID) -> String?; func setLabel(_ s: String?, for: TVID); var changes: AsyncStream<Void> { get } }`; `final class ICloudLabelStore: LabelStore` over `NSUbiquitousKeyValueStore` (key `label.<id>`; empty/whitespace → remove; trimmed; max 40 chars).
  - `struct FileKnownTVStore { init(url: URL); func load() -> KnownTVRegistry; func save(_ r: KnownTVRegistry) throws /* atomic */ }` — default URL `Application Support/known-tvs.json`; corrupt file → empty registry (logged), never crash.
- [ ] **Step 1: Failing tests:** keychain round-trip, overwrite, delete (unique service per test); label trim/clear/length cap with an in-memory KVS double; file store round-trip and corrupt-file-yields-empty.
- [ ] **Step 2:** Run app tests → FAIL.
- [ ] **Step 3:** Implement; app shows a placeholder view.
- [ ] **Step 4:** Run app tests → PASS; `xcodebuild build` for device with owner's xcconfig succeeds (signing with the team from `Local.xcconfig`).
- [ ] **Step 5:** Commit `feat(app): Xcode project, config and platform stores`; push.

### Task 14: App model

**Files:** Create `App/FreeRemote/AppModel.swift`, `App/FreeRemote/RepeatController.swift`; Tests `AppModelTests.swift`, `RepeatControllerTests.swift`.

**Interfaces:**
- Consumes: `DiscoveryCoordinator`, `RemoteSession`, `PowerController`, stores, `NetworkInterfaces`.
- Produces:
  - `struct TVListItem: Identifiable, Equatable { id: TVID; title: String /* label ?? reportedName */; subtitle: String /* model */; status: TVStatus }`, `enum TVStatus { case on, asleep, unreachable, pairing }`
  - `enum ScreenState: Equatable { case noWiFi, localNetworkDenied, searching, noTVs, ready, pairing, pairingDenied, identityChanged }`
  - `@MainActor @Observable final class AppModel { init(env: AppEnvironment); var tvs: [TVListItem]; var selectedID: TVID?; var screen: ScreenState; var powerBusy: Bool; var keyboardRequested: Bool; func onAppear(); func scenePhaseChanged(_: ScenePhase); func select(_: TVID); func rescan(); func press(_: RemoteKey); func beginHold(_: RemoteKey); func endHold(); func togglePower(); func sendText(_: String); func rename(_: TVID, to: String?); func forget(_: TVID); func addManually(host: String) async -> Bool; func repair() }`
  - `struct AppEnvironment` bundles factories for every dependency (real in app, fakes in tests/demo).
  - `@MainActor final class RepeatController { init(clock: any Clock<Duration>, strategy: RepeatStrategy, send: @escaping (RemoteKey, KeyAction) async -> Void); func begin(_: RemoteKey); func end() }` — `end()` (also called on background and disconnect) always stops repetition and sends `.release` if `.pressRelease`.
  - Last selected id persisted in `UserDefaults` key `selectedTV`.
- [ ] **Step 1: Failing tests:** `noWiFiShowsWiFiState`; `discoveredTVsListedOnlineFirst`; `labelOverridesReportedName`; `reconnectsAfterIPChange`; `selectionRestoredOnLaunch`; `backgroundDisconnectsForegroundReconnects`; `pressWhileDisconnectedShowsReason` (no silent no-op); `forgetRemovesEverything` (registry, label, credentials); `addManuallyRejectsPublicIP`; `cancelStopsRepeatingAndSendsRelease`; `backgroundEndsHold`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5:** Commit `feat(app): app model and hold-to-repeat`; push.

### Task 15: Remote screen (layout B)

**Files:** Create `Views/{RemoteView,TVPicker,DPad,Rocker,RemoteButton,StatusView}.swift`; modify `FreeRemoteApp.swift`.

Layout B exactly as approved mockup: picker card at top (status dot + label + status text, chevron) → row [Power (red), Source (wide; long-press → menu HDMI 1–4), Mute] → circular D-pad with OK → bottom row [VOL rocker | 2×2 Back, Home, Play/Pause, 123 | CH rocker]. Dark-first, adapts to light. `.sensoryFeedback(.impact(weight: .light), …)` per press. Rockers and arrows use `beginHold`/`endHold`. Buttons disabled (dimmed) with `StatusView` explaining why when `screen != .ready`. Every control: `accessibilityLabel` (e.g. "Volume up"), `accessibilityHint` where useful; `.accessibilityAddTraits(.isButton)`.

- [ ] **Step 1:** Add SwiftUI `#Preview`s with `DemoEnvironment` (Task 17 stub: a minimal in-memory fake env, created now in `Demo/DemoEnvironment.swift`).
- [ ] **Step 2:** Build; screenshot in the iPhone 17 Pro simulator (`xcrun simctl io booted screenshot`) and compare against the approved mockup; also with largest Dynamic Type and VoiceOver labels audited via Accessibility Inspector.
- [ ] **Step 3:** Install on the owner's iPhone with real TVs (owner present): every button works on all three TVs.
- [ ] **Step 4:** Commit `feat(app): remote screen layout B`; push.

### Task 16: Sheets and states

**Files:** Create `Views/{NumberPadSheet,TextEntrySheet,RenameSheet,AddTVSheet}.swift`; modify `TVPicker.swift`, `StatusView.swift`.

Copy (exact):
- Rename note: "This name is only on your devices. To change the name everyone sees, rename the TV in its Settings → General → Device Name." (adjust path per Task 12 findings).
- noTVs: "No TVs found. Make sure your iPhone and TV are on the same Wi-Fi network and the TV is on." + button "Scan Again" + "Add TV by IP Address".
- localNetworkDenied: "Free Remote needs Local Network access to find your TV." + "Open Settings" (`UIApplication.openSettingsURLString`).
- noWiFi: "Connect to Wi-Fi to control your TV."
- pairing: "Look at your TV and choose Allow."
- pairingDenied: "Your TV blocked this iPhone. On the TV, open Settings → General → External Device Manager → Device Connection Manager → Device List, allow Free Remote, then tap Try Again."
- identityChanged: "This TV's security identity changed (this can happen after a software update). Pair again to continue." + "Pair Again".
- failedToWake: "Couldn't turn on the TV. Turn on “Power On with Mobile” in the TV's network settings, then try again."
- [ ] **Step 1:** Add UI tests in `FlowUITests.swift` using launch argument `-demo` (Task 17 env): `renameUpdatesPicker`, `numberPadSendsDigits`, `addTVRejectsPublicIP`, `emptyStateShowsScanAgain`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(app): sheets, empty and error states`; push.

### Task 17: Demo mode + screenshots

**Files:** Complete `Demo/DemoEnvironment.swift` (activated by launch argument `-demo`; three fictional TVs "Living Room", "Bedroom", "Patio" with generic models; all commands succeed locally); create `FreeRemoteUITests/ScreenshotTests.swift` saving screenshots as XCTest attachments; script `scripts/screenshots.sh` exporting them to `AppStore/screenshots/` for iPhone 17 Pro Max (6.9") and iPhone 17 Pro.

- [ ] **Step 1:** Run `scripts/screenshots.sh` → PNGs produced for: remote screen, picker open, rename sheet.
- [ ] **Step 2:** Commit `feat(app): demo mode and App Store screenshots`; push.

### Task 18: Icon, listing, privacy, docs

**Files:** Create `App/FreeRemote/Resources/Assets.xcassets/AppIcon` (original artwork: a minimalist remote silhouette, single 1024 px light/dark/tinted variants; no Samsung marks), `AppStore/listing.md` (name, subtitle "Remote control for Samsung TVs", promo text, description, keywords, category Utilities, age 4+, privacy "Data Not Collected", support URL = GitHub issues, privacy URL = GitHub Pages, **Requirements** section per spec §6.9 with the tested-years wording from Task 12, trademark disclaimer "Not affiliated with or endorsed by Samsung."), `AppStore/review-notes.md`, `docs/privacy/index.md`, `README.md` (full), `CONTRIBUTING.md`, `.github/ISSUE_TEMPLATE/{bug_report,tv_compatibility}.md`, `docs/testing/manual-checklist.md`.

- [ ] **Step 1:** Enable GitHub Pages from `/docs` (`gh api -X POST repos/{owner}/{repo}/pages -f 'source[branch]=main' -f 'source[path]=/docs'`), confirm privacy URL serves 200.
- [ ] **Step 2:** Run `../samsung-free-remote-ios-app-private/privacy-check.sh --all` over the whole public tree → nothing.
- [ ] **Step 3:** Commit `docs: App Store listing, privacy policy, contributor docs, icon`; push.

### Task 19: Release verification

- [ ] **Step 1:** Kit + app test suites green locally and in CI.
- [ ] **Step 2:** Once Apple grants the multicast entitlement: run `docs/testing/manual-checklist.md` on the owner's iPhone against all three TVs (discovery incl. the SSDP-silent TV, pairing, every button, hold-repeat, power off, power on from standby and from deep sleep, IP change via router lease renewal, pairing denied + recovery, airplane mode, Local Network denied). Record results in the private repo.
- [ ] **Step 3:** Archive with `xcodebuild archive` using owner's signing; validate (`xcodebuild -exportArchive` with App Store method). Hand over to owner to upload/submit.
- [ ] **Step 4:** Commit any fixes; tag `v1.0.0`; push tags.
