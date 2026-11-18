import Foundation

/// A TV the user has seen before, keyed by its stable `TVID` so DHCP address changes keep its identity.
public struct KnownTV: Codable, Equatable, Sendable {
    public var id: TVID
    public var lastHost: String
    public var wifiMAC: MACAddress?
    public var modelName: String
    public var reportedName: String
    public var lastSeen: Date

    public init(id: TVID, lastHost: String, wifiMAC: MACAddress?, modelName: String, reportedName: String, lastSeen: Date) {
        self.id = id
        self.lastHost = lastHost
        self.wifiMAC = wifiMAC
        self.modelName = modelName
        self.reportedName = reportedName
        self.lastSeen = lastSeen
    }
}

/// The set of known TVs.
public struct KnownTVRegistry: Codable, Equatable, Sendable {
    public private(set) var tvs: [TVID: KnownTV] = [:]

    public init() {}

    /// Inserts or refreshes the TV described by `info`. A known Wi-Fi MAC is kept when `info` has none.
    public mutating func record(_ info: TVDeviceInfo, at date: Date) {
        tvs[info.id] = KnownTV(
            id: info.id,
            lastHost: info.host,
            wifiMAC: info.wifiMAC ?? tvs[info.id]?.wifiMAC,
            modelName: info.modelName,
            reportedName: info.name,
            lastSeen: date
        )
    }

    public mutating func forget(_ id: TVID) {
        tvs[id] = nil
    }
}
