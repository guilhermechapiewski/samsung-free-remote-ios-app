import Foundation

public enum TVPowerState: Equatable, Sendable {
    case on
    case standby
    case unknown(String)
}

public enum TVInfoError: Error, Equatable {
    case malformed
    case notSamsungTizen
    case tooLarge
    case unreachable
    case notLocalAddress
}

/// Facts about a TV from `GET http://<host>:8001/api/v2/`.
public struct TVDeviceInfo: Equatable, Sendable {
    public var id: TVID
    public var host: String
    public var name: String
    public var modelName: String
    public var modelCode: String
    public var wifiMAC: MACAddress?
    public var networkType: String
    public var powerState: TVPowerState
    public var tokenAuthSupported: Bool

    public init(
        id: TVID, host: String, name: String, modelName: String, modelCode: String,
        wifiMAC: MACAddress?, networkType: String, powerState: TVPowerState, tokenAuthSupported: Bool
    ) {
        self.id = id
        self.host = host
        self.name = name
        self.modelName = modelName
        self.modelCode = modelCode
        self.wifiMAC = wifiMAC
        self.networkType = networkType
        self.powerState = powerState
        self.tokenAuthSupported = tokenAuthSupported
    }

    public static func decode(_ data: Data, host: String) throws(TVInfoError) -> TVDeviceInfo {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw .malformed
        }
        let device = response.device
        guard device.type == "Samsung SmartTV", device.OS == "Tizen" else { throw .notSamsungTizen }

        // Absent: older TVs omit the field and only answer while on.
        let power: TVPowerState
        switch device.PowerState {
        case "on", nil: power = .on
        case "", "standby": power = .standby
        case let other?: power = .unknown(other)
        }

        return TVDeviceInfo(
            id: TVID(rawValue: device.id),
            host: host,
            name: HTMLEntities.decode(device.name ?? response.name ?? ""),
            modelName: device.modelName ?? "",
            modelCode: device.model ?? "",
            wifiMAC: device.wifiMac.flatMap(MACAddress.init),
            networkType: device.networkType ?? "",
            powerState: power,
            tokenAuthSupported: device.TokenAuthSupport == "true"
        )
    }

    private struct Response: Decodable {
        let name: String?
        let device: Device
    }

    // Property names mirror the TV's JSON keys.
    private struct Device: Decodable {
        let id: String
        let name: String?
        let type: String?
        let OS: String?
        let model: String?
        let modelName: String?
        let wifiMac: String?
        let networkType: String?
        let PowerState: String?
        let TokenAuthSupport: String?
    }
}
