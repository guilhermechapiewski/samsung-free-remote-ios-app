// tvprobe: developer tool for exercising SamsungTVKit against real or fake TVs. Not shipped.
import Foundation
import SamsungTVKit

let usage = """
usage:
  tvprobe discover
  tvprobe info <host>
  tvprobe key <host> <KEY> [click|press|release]
  tvprobe hold <host> <KEY> <seconds>
  tvprobe text <host> <string>
  tvprobe listen <host>
  tvprobe wake <mac> [host] [--no-broadcast]   (host: also send a unicast packet to it)
"""

/// Hidden: saves and loads a dummy credential in a temp directory and prints the file and directory modes.
func credstoreSelfTest() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tvprobe-selftest-\(UUID().uuidString)")
    let file = dir.appendingPathComponent("credentials.json")
    let store = FileCredentialStore(url: file)
    let id = TVID(rawValue: "selftest")
    let pin = try! JSONDecoder().decode(CertificatePin.self, from: Data(#"{"sha256":"AAEC"}"#.utf8))
    let creds = TVCredentials(token: "dummy", pin: pin)
    do { try store.save(creds, for: id) } catch { fail("selftest save failed: \(error)") }
    guard store.load(id) == creds else { fail("selftest load mismatch") }
    func mode(_ u: URL) -> String {
        let m = (try? FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? Int) ?? 0
        return String(m & 0o777, radix: 8)
    }
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? -1
    print("file mode: \(mode(file))\ndir mode: \(mode(dir))\nentries in dir: \(leftovers)")
    try? FileManager.default.removeItem(at: dir)
}

func fail(_ message: String, showUsage: Bool = false) -> Never {
    FileHandle.standardError.write(Data((message + (showUsage ? "\n" + usage : "") + "\n").utf8))
    exit(1)
}

func out(_ s: String) { print(s) }

// MARK: - Credentials (dev only: plain JSON file, 0600)

final class FileCredentialStore: CredentialStore {
    private let lock = NSLock()
    private let url: URL

    init(url: URL? = nil) {
        if let url { self.url = url; return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = base.appendingPathComponent("tvprobe/credentials.json")
    }

    private func readAll() -> [String: TVCredentials] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            return try JSONDecoder().decode([String: TVCredentials].self, from: Data(contentsOf: url))
        } catch {
            fail("credentials file \(url.path) is unreadable or corrupt (\(error)); refusing to overwrite it")
        }
    }

    private func writeAll(_ all: [String: TVCredentials]) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let data = try JSONEncoder().encode(all)
        let tmp = dir.appendingPathComponent(".credentials.\(UUID().uuidString).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var open = true
        do {
            try data.withUnsafeBytes { buf in
                var offset = 0
                while offset < buf.count {
                    let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            open = false
            guard close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard rename(tmp, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            if open { close(fd) }
            unlink(tmp)
            throw error
        }
    }

    func load(_ id: TVID) -> TVCredentials? {
        lock.lock(); defer { lock.unlock() }
        return readAll()[id.rawValue]
    }

    func save(_ c: TVCredentials, for id: TVID) throws {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all[id.rawValue] = c
        try writeAll(all)
    }

    func delete(_ id: TVID) {
        lock.lock(); defer { lock.unlock() }
        var all = readAll()
        all[id.rawValue] = nil
        try? writeAll(all)
    }
}

// MARK: - Helpers

func powerText(_ p: TVPowerState) -> String {
    switch p {
    case .on: "on"
    case .standby: "standby"
    case .unknown(let s): "unknown(\(s))"
    }
}

func fetchInfo(_ host: String) async -> TVDeviceInfo {
    do { return try await HTTPTVInfoFetcher().fetchInfo(host: host) }
    catch { fail("info failed for \(host): \(error)") }
}

func makeSession(host: String) async -> RemoteSession {
    let info = await fetchInfo(host)
    return RemoteSession(id: info.id, host: host, credentials: FileCredentialStore(),
                         transport: { URLSessionWebSocketTransport() })
}

func waitConnected(_ session: RemoteSession) async {
    await session.connect()
    for await state in session.states {
        switch state {
        case .connected: return
        case .awaitingApproval: out("waiting for approval on the TV...")
        case .failed(let e): fail("session failed: \(e)")
        default: break
        }
    }
    fail("session ended before connecting")
}

func parseKey(_ s: String) -> RemoteKey {
    guard let key = RemoteKey(rawValue: s) else {
        fail("unknown key \(s); known: " + RemoteKey.allCases.map(\.rawValue).joined(separator: " "))
    }
    return key
}

/// First up, private, non-loopback IPv4 interface (Wi-Fi is not always en0 on a Mac).
func firstPrivateInterface() -> IPv4Interface? {
    NetworkInterfaces.current().first {
        $0.netmask != 0 && !$0.name.hasPrefix("lo") && LocalAddress.isAllowed($0.addressString)
    }
}

// MARK: - Commands

func discover() async {
    let coordinator = DiscoveryCoordinator(
        sources: [SSDPSearcher(duration: .seconds(5)), BonjourSamsungBrowser(duration: .seconds(5))],
        fetcher: HTTPTVInfoFetcher(), knownHosts: [])
    var count = 0
    for await event in await coordinator.scan() {
        switch event {
        case .found(let i):
            count += 1
            out("\(i.id.rawValue)  \(i.host)  \(i.modelName)  \(powerText(i.powerState))  \(i.name)")
        case .localNetworkDenied:
            out("local network access denied")
        }
    }
    out("\(count) TV(s) found")
}

func info(_ host: String) async {
    let i = await fetchInfo(host)
    out("id: \(i.id.rawValue)")
    out("host: \(i.host)")
    out("name: \(i.name)")
    out("model: \(i.modelName) (\(i.modelCode))")
    out("mac: \(i.wifiMAC?.description ?? "-")")
    out("network: \(i.networkType)")
    out("power: \(powerText(i.powerState))")
    out("tokenAuth: \(i.tokenAuthSupported)")
}

func key(_ host: String, _ keyName: String, _ actionName: String) async {
    let k = parseKey(keyName)
    let action: KeyAction
    switch actionName.lowercased() {
    case "click": action = .click
    case "press": action = .press
    case "release": action = .release
    default: fail("action must be click, press or release", showUsage: true)
    }
    let session = await makeSession(host: host)
    await waitConnected(session)
    do { try await session.send(k, action) } catch { fail("send failed: \(error)") }
    try? await Task.sleep(for: .milliseconds(300))
    await session.disconnect()
}

func hold(_ host: String, _ keyName: String, _ seconds: Double) async {
    let k = parseKey(keyName)
    let session = await makeSession(host: host)
    await waitConnected(session)
    guard case .clickEvery(let interval) = RepeatStrategy.default else { fail("default strategy is not clickEvery") }
    var pressed = false
    do {
        out("press/release for \(seconds)s")
        try await session.send(k, .press)
        pressed = true
        try await Task.sleep(for: .seconds(seconds))
        try await session.send(k, .release)
        pressed = false
        try await Task.sleep(for: .seconds(1))
        out("repeated click every \(interval) for \(seconds)s")
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            try await session.send(k, .click)
            try await Task.sleep(for: interval)
        }
    } catch {
        if pressed { try? await session.send(k, .release) }
        fail("hold failed: \(error)")
    }
    await session.disconnect()
}

func text(_ host: String, _ string: String) async {
    let session = await makeSession(host: host)
    await waitConnected(session)
    do {
        try await session.sendText(string)
        try await session.sendTextEnd()
    } catch { fail("text failed: \(error)") }
    try? await Task.sleep(for: .milliseconds(300))
    await session.disconnect()
}

func listen(_ host: String) async {
    let session = await makeSession(host: host)
    await session.connect()
    Task { for await s in session.states { out("state: \(s)") } }
    for await shown in session.keyboardEvents { out("keyboard: \(shown ? "shown" : "hidden")") }
}

func wake(_ args: [String]) async {
    let broadcast = !args.contains("--no-broadcast")
    let positional = args.filter { $0 != "--no-broadcast" }
    guard (1...2).contains(positional.count), let mac = MACAddress(positional[0]) else {
        fail("invalid MAC", showUsage: true)
    }
    let host = positional.count == 2 ? positional[1] : nil
    if let host, !LocalAddress.isAllowed(host) { fail("host must be a private IPv4 address", showUsage: true) }
    guard host != nil || broadcast else { fail("--no-broadcast needs a host", showUsage: true) }
    guard let iface = firstPrivateInterface() else { fail("no up private IPv4 interface") }
    let targets = WakeOnLAN.targets(via: iface, host: host, broadcast: broadcast)
    out("sending magic packet via \(iface.name) to \(targets.joined(separator: ", "))")
    await WakeOnLAN.send(to: mac, via: iface, host: host, broadcast: broadcast)
}

// MARK: - Dispatch

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("missing command", showUsage: true) }
let rest = Array(args.dropFirst())

switch (command, rest.count) {
case ("_selftest-credstore", 0): credstoreSelfTest()
case ("discover", 0): await discover()
case ("info", 1): await info(rest[0])
case ("key", 2), ("key", 3): await key(rest[0], rest[1], rest.count == 3 ? rest[2] : "click")
case ("hold", 3):
    guard let secs = Double(rest[2]), secs > 0 else { fail("seconds must be a positive number", showUsage: true) }
    await hold(rest[0], rest[1], secs)
case ("text", 2): await text(rest[0], rest[1])
case ("listen", 1): await listen(rest[0])
case ("wake", 1...3): await wake(rest)
default: fail("bad arguments", showUsage: true)
}
